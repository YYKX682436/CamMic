import AVFoundation
import Dispatch
import Foundation
import XCTest
@testable import CamMic

final class AudioCaptureQueueTests: XCTestCase {
    func testCaptureQueueKeepsFixedEightBufferPoolAndDropsOldestWhenFull() {
        let queue = makeQueue(slotCount: 8)
        defer { queue.finish() }
        let source = makeSourceBuffer()

        for index in 0..<8 {
            XCTAssertEqual(queue.copyFromSystemBuffer(source, capturedAtNanoseconds: UInt64(index)), .copied)
        }
        XCTAssertEqual(queue.copyFromSystemBuffer(source, capturedAtNanoseconds: 8), .copied)
        XCTAssertEqual(queue.copyFromSystemBuffer(source, capturedAtNanoseconds: 9), .copied)
        XCTAssertEqual(queue.bufferedFramesForTesting, 8 * 1024)
        XCTAssertEqual(queue.metricsSnapshot.maximumObservedBufferedFrames, 8 * 1024)
        XCTAssertEqual(queue.droppedFramesForTesting, 2 * 1024)

        var capturedAt: [UInt64] = []
        for _ in 0..<8 {
            guard let item = queue.take() else { return XCTFail("The fixed queue should keep eight latest slots") }
            capturedAt.append(item.capturedAtNanoseconds)
            queue.release(item.index)
        }
        XCTAssertEqual(capturedAt, Array(2...9).map(UInt64.init))
    }

    func testSingleSystemBufferMayExceedLegacy4096FrameSlotWithExplicitBound() {
        let queue = makeQueue(slotCount: 8, maximumFrames: 16_384, maximumBufferedFrames: 14_400)
        defer { queue.finish() }
        let source = makeSourceBuffer(frameLength: 8192)

        XCTAssertEqual(queue.copyFromSystemBuffer(source, capturedAtNanoseconds: 1), .copied)
        guard let item = queue.take() else { return XCTFail("The copied buffer should be available") }
        queue.release(item.index)
    }

    func testInputBeyondPreallocatedSlotRemainsFatalAndIsReported() {
        let queue = makeQueue(slotCount: 2, maximumFrames: 1_024, maximumBufferedFrames: 4_096)
        defer { queue.finish() }
        let oversized = makeSourceBuffer(frameLength: 2_048)

        guard case .overrun(let diagnostic) = queue.copyFromSystemBuffer(oversized, capturedAtNanoseconds: 1) else {
            return XCTFail("An input block larger than every preallocated slot is not safely recoverable")
        }
        XCTAssertEqual(diagnostic.reason, .inputFrameExceedsSlot(actual: 2_048, maximum: 1_024))
        XCTAssertEqual(queue.copyFromSystemBuffer(makeSourceBuffer(), capturedAtNanoseconds: 2), .ignored)
        XCTAssertEqual(queue.droppedFramesForTesting, 2_048)
    }

    func testQueueDropsOldestQueuedAudioWhenItsDurationBoundIsReached() {
        let queue = makeQueue(slotCount: 4, maximumFrames: 4096, maximumBufferedFrames: 2048)
        defer { queue.finish() }
        let source = makeSourceBuffer()

        XCTAssertEqual(queue.copyFromSystemBuffer(source, capturedAtNanoseconds: 1), .copied)
        XCTAssertEqual(queue.copyFromSystemBuffer(source, capturedAtNanoseconds: 2), .copied)
        XCTAssertEqual(queue.copyFromSystemBuffer(source, capturedAtNanoseconds: 3), .copied)
        XCTAssertEqual(queue.bufferedFramesForTesting, 2048)
        XCTAssertEqual(queue.droppedFramesForTesting, 1024)

        var capturedAt: [UInt64] = []
        for _ in 0..<2 {
            guard let item = queue.take() else { return XCTFail("The newest queued audio should remain available") }
            capturedAt.append(item.capturedAtNanoseconds)
            queue.release(item.index)
        }
        XCTAssertEqual(capturedAt, [2, 3], "Queue pressure must discard only the oldest pending audio")
    }

    func testCaptureCancellationDiscardsQueuedPCMAndWakesTheWorker() {
        let queue = makeQueue(slotCount: 4, maximumFrames: 4096, maximumBufferedFrames: 4096)
        let source = makeSourceBuffer()
        XCTAssertEqual(queue.copyFromSystemBuffer(source, capturedAtNanoseconds: 1), .copied)
        XCTAssertEqual(queue.copyFromSystemBuffer(source, capturedAtNanoseconds: 2), .copied)
        XCTAssertEqual(queue.bufferedFramesForTesting, 2_048)

        queue.cancelPending()

        XCTAssertEqual(queue.bufferedFramesForTesting, 0, "Manual stop or interruption must release queued PCM slots")
        XCTAssertNil(queue.take(), "A cancelled worker must wake and exit without converting old audio")
    }

    func testReported44100HzCallbacksStayWithin300MillisecondsByDroppingOldestOnFourthBlock() {
        let maximumBufferedFrames: AVAudioFrameCount = 13_230
        let queue = makeQueue(
            slotCount: 12,
            maximumFrames: 16_384,
            maximumBufferedFrames: maximumBufferedFrames,
            sampleRate: 44_100
        )
        defer { queue.finish() }
        let source = makeSourceBuffer(frameLength: 4_410, sampleRate: 44_100)

        XCTAssertEqual(queue.copyFromSystemBuffer(source, capturedAtNanoseconds: 1), .copied)
        XCTAssertEqual(queue.copyFromSystemBuffer(source, capturedAtNanoseconds: 2), .copied)
        XCTAssertEqual(queue.copyFromSystemBuffer(source, capturedAtNanoseconds: 3), .copied)
        XCTAssertEqual(queue.copyFromSystemBuffer(source, capturedAtNanoseconds: 4), .copied)
        XCTAssertEqual(queue.bufferedFramesForTesting, maximumBufferedFrames)
        XCTAssertEqual(queue.metricsSnapshot.maximumObservedBufferedFrames, maximumBufferedFrames)
        XCTAssertEqual(queue.droppedFramesForTesting, 4_410)

        var capturedAt: [UInt64] = []
        for _ in 0..<3 {
            guard let item = queue.take() else { return XCTFail("The queue should contain three current callbacks") }
            capturedAt.append(item.capturedAtNanoseconds)
            queue.release(item.index)
        }
        XCTAssertEqual(capturedAt, [2, 3, 4])
    }

    func testPrestartedConsumerDrainsMoreThanPoolCapacityWithoutOverrun() {
        let queue = makeQueue(slotCount: 8, maximumFrames: 4096, maximumBufferedFrames: 4096)
        let source = makeSourceBuffer()
        let workerReady = DispatchSemaphore(value: 0)
        let consumedBuffer = DispatchSemaphore(value: 0)
        let workerFinished = DispatchSemaphore(value: 0)
        let bufferCount = 64

        DispatchQueue(label: "CamMicTests.audio-queue-consumer", qos: .userInitiated).async {
            workerReady.signal()
            defer { workerFinished.signal() }
            for _ in 0..<bufferCount {
                guard let item = queue.take() else { return }
                queue.release(item.index)
                consumedBuffer.signal()
            }
        }

        guard workerReady.wait(timeout: .now() + 1) == .success else {
            queue.finish()
            XCTFail("The consumer did not start before the producer")
            return
        }

        for index in 0..<bufferCount {
            let result = queue.copyFromSystemBuffer(source, capturedAtNanoseconds: UInt64(index))
            guard result == .copied else {
                queue.finish()
                _ = workerFinished.wait(timeout: .now() + 1)
                XCTFail("The bounded queue overran at input buffer \(index)")
                return
            }
            guard consumedBuffer.wait(timeout: .now() + 1) == .success else {
                queue.finish()
                _ = workerFinished.wait(timeout: .now() + 1)
                XCTFail("The consumer did not drain input buffer \(index)")
                return
            }
        }

        queue.finish()
        XCTAssertEqual(workerFinished.wait(timeout: .now() + 1), .success)
    }

    func testProductionPipelineKeepsFiveLarge48kBlocksContinuousAs64TransportFrames() throws {
        let format = audioFormat()
        let pipeline = try makePipeline(inputFormat: format)
        var frames: [CapturePCM16Pipeline.AudioFrame] = []
        let blockLength = 12_288

        for block in 0..<5 {
            let buffer = makeSignalBuffer(format: format, frameLength: blockLength, startIndex: block * blockLength)
            frames.append(contentsOf: try pipeline.append(
                buffer,
                capturedAtNanoseconds: UInt64(block * blockLength)
            ))
        }

        XCTAssertEqual(pipeline.convertedSampleCount, 61_440)
        XCTAssertEqual(frames.count, 64)
        XCTAssertTrue(frames.allSatisfy { $0.pcm.count == CamMicFrameCodec.audioPayloadLength })
        XCTAssertEqual(pipeline.pendingSampleCount, 0)

        let rendered = decode(frames)
        XCTAssertEqual(rendered.count, 61_440)
        for index in rendered.indices {
            XCTAssertLessThanOrEqual(
                abs(Int(rendered[index]) - Int(expectedRampSample(index))),
                2,
                "Sample discontinuity at output index \(index)"
            )
        }
    }

    func testProductionPipelineConverts8192InputFramesAndKeepsPartialTransportFrame() throws {
        let format = audioFormat()
        let pipeline = try makePipeline(inputFormat: format)
        let input = makeSignalBuffer(format: format, frameLength: 8_192, startIndex: 0)

        let frames = try pipeline.append(input, capturedAtNanoseconds: 1)

        XCTAssertEqual(pipeline.convertedSampleCount, 8_192)
        XCTAssertEqual(frames.count, 8)
        XCTAssertEqual(pipeline.pendingSampleCount, 512)
        let rendered = decode(frames)
        for index in rendered.indices {
            XCTAssertLessThanOrEqual(
                abs(Int(rendered[index]) - Int(expectedRampSample(index))),
                2,
                "Sample discontinuity at output index \(index)"
            )
        }
    }

    func testProductionPipelineResamples44100BlockBeyond8192AndFlushesFiniteTail() throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 1,
            interleaved: false
        )!
        let pipeline = try makePipeline(inputFormat: format)
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192)!
        input.frameLength = 8_192
        let samples = input.floatChannelData!.pointee
        for index in 0..<8_192 {
            samples[index] = Float(0.5 * sin(2 * Double.pi * 440 * Double(index) / format.sampleRate))
        }

        var frames = try pipeline.append(input, capturedAtNanoseconds: 1)
        frames.append(contentsOf: try pipeline.finish(capturedAtNanoseconds: 2))

        let outputCount = Int(pipeline.convertedSampleCount)
        let expectedCount = Int((8_192.0 * 48_000.0 / 44_100.0).rounded())
        XCTAssertGreaterThan(outputCount, 8_192)
        XCTAssertLessThanOrEqual(abs(outputCount - expectedCount), 128, "Only the converter's finite resampling boundary may differ")
        XCTAssertEqual(outputCount, frames.count * Int(CamMicFrameCodec.samplesPerFrame) + pipeline.pendingSampleCount)
        let rendered = decode(frames)
        let rms = sqrt(rendered.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, rendered.count)))
        XCTAssertGreaterThan(rms, 8_000, "The 440 Hz input signal must survive resampling")
        for index in 1..<rendered.count {
            XCTAssertLessThan(
                abs(Int(rendered[index]) - Int(rendered[index - 1])),
                6_000,
                "The resampled waveform must remain continuous at output index \(index)"
            )
        }
    }

    func testProductionPipelineKeepsRepeated4410Frame44100HzCallbacksContinuous() throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 1,
            interleaved: false
        )!
        let pipeline = try makePipeline(inputFormat: format)
        var frames: [CapturePCM16Pipeline.AudioFrame] = []
        let callbackFrames = 4_410
        let callbackCount = 20

        for callback in 0..<callbackCount {
            let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(callbackFrames))!
            input.frameLength = AVAudioFrameCount(callbackFrames)
            let samples = input.floatChannelData!.pointee
            for index in 0..<callbackFrames {
                let absoluteIndex = callback * callbackFrames + index
                samples[index] = Float(0.5 * sin(2 * Double.pi * 440 * Double(absoluteIndex) / format.sampleRate))
            }
            frames.append(contentsOf: try pipeline.append(
                input,
                capturedAtNanoseconds: UInt64(callback * 100_000_000)
            ))
        }
        frames.append(contentsOf: try pipeline.finish(capturedAtNanoseconds: 2_000_000_000))

        let expectedSamples = Int(Double(callbackFrames * callbackCount) * 48_000 / 44_100)
        XCTAssertLessThanOrEqual(abs(Int(pipeline.convertedSampleCount) - expectedSamples), 128)
        XCTAssertEqual(pipeline.convertedSampleCount,
                       UInt64(frames.count * Int(CamMicFrameCodec.samplesPerFrame) + pipeline.pendingSampleCount))
        XCTAssertTrue(frames.allSatisfy { $0.pcm.count == CamMicFrameCodec.audioPayloadLength })
        let rendered = decode(frames)
        XCTAssertGreaterThan(rendered.count, 90_000)
        for index in 1..<rendered.count {
            XCTAssertLessThan(
                abs(Int(rendered[index]) - Int(rendered[index - 1])),
                6_000,
                "The 44.1 kHz callback boundary must not create a PCM discontinuity at sample \(index)"
            )
        }
    }

    func testProductionPipelineHandlesSmallInputWithoutLosingTheNextFrameBoundary() throws {
        let format = audioFormat()
        let pipeline = try makePipeline(inputFormat: format)
        let input = makeSignalBuffer(format: format, frameLength: 1_024, startIndex: 0)

        let frames = try pipeline.append(input, capturedAtNanoseconds: 5)

        XCTAssertEqual(pipeline.convertedSampleCount, 1_024)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(pipeline.pendingSampleCount, 64)
        XCTAssertEqual(frames[0].capturedAtNanoseconds, 5)
    }

    func testTapCopyDoesNotWaitForOccupiedConsumerStateAndCountsDroppedCallbacks() {
        let queue = makeQueue(slotCount: 2)
        defer { queue.finish() }
        let source = makeSourceBuffer()
        let acquired = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let holderFinished = DispatchSemaphore(value: 0)
        queue.holdStateLockForTesting(acquired: acquired, release: release, finished: holderFinished)
        guard acquired.wait(timeout: .now() + 5) == .success else {
            release.signal()
            XCTFail("The test thread did not acquire the consumer state lock")
            return
        }

        let firstResultReady = DispatchSemaphore(value: 0)
        let firstResult = CopyResultBox()
        DispatchQueue.global(qos: .userInitiated).async {
            firstResult.store(queue.copyFromSystemBuffer(source, capturedAtNanoseconds: 11))
            firstResultReady.signal()
        }
        let returnedBeforeUnlock = firstResultReady.wait(timeout: .now() + 5) == .success
        let secondResultReady = DispatchSemaphore(value: 0)
        let secondResult = CopyResultBox()
        DispatchQueue.global(qos: .userInitiated).async {
            secondResult.store(queue.copyFromSystemBuffer(source, capturedAtNanoseconds: 12))
            secondResultReady.signal()
        }
        let secondReturnedBeforeUnlock = secondResultReady.wait(timeout: .now() + 5) == .success
        release.signal()
        XCTAssertEqual(holderFinished.wait(timeout: .now() + 5), .success)
        if !returnedBeforeUnlock { _ = firstResultReady.wait(timeout: .now() + 5) }
        if !secondReturnedBeforeUnlock { _ = secondResultReady.wait(timeout: .now() + 5) }

        XCTAssertTrue(returnedBeforeUnlock, "The tap callback must return before the consumer releases the lock")
        XCTAssertTrue(secondReturnedBeforeUnlock)
        XCTAssertEqual(firstResult.load(), .ignored, "Contended callbacks should be dropped without stopping capture")
        XCTAssertEqual(secondResult.load(), .ignored)
        XCTAssertEqual(queue.bufferedFramesForTesting, 0)
        XCTAssertEqual(queue.droppedFramesForTesting, UInt64(2 * source.frameLength))
        XCTAssertEqual(queue.copyFromSystemBuffer(source, capturedAtNanoseconds: 13), .copied,
                       "Transient lock contention must not poison the rest of the capture run")
    }

    private func makeQueue(
        slotCount: Int,
        maximumFrames: AVAudioFrameCount = 4096,
        maximumBufferedFrames: AVAudioFrameCount = 65_536,
        sampleRate: Double = 48_000
    ) -> BoundedPCMQueue {
        BoundedPCMQueue(
            format: audioFormat(sampleRate: sampleRate),
            slotCount: slotCount,
            maximumFrames: maximumFrames,
            maximumBufferedFrames: maximumBufferedFrames
        )
    }

    private func makeSourceBuffer(
        frameLength: AVAudioFrameCount = 1024,
        sampleRate: Double = 48_000
    ) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat(sampleRate: sampleRate), frameCapacity: frameLength)!
        buffer.frameLength = frameLength
        return buffer
    }

    private func audioFormat(sampleRate: Double = 48_000) -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
    }

    private func makePipeline(inputFormat: AVAudioFormat) throws -> CapturePCM16Pipeline {
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
        let converter = AVAudioConverter(from: inputFormat, to: outputFormat)!
        return try CapturePCM16Pipeline(
            converter: converter,
            inputFormat: inputFormat,
            outputFormat: outputFormat
        )
    }

    private func makeSignalBuffer(format: AVAudioFormat, frameLength: Int, startIndex: Int) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameLength))!
        buffer.frameLength = AVAudioFrameCount(frameLength)
        let samples = buffer.floatChannelData!.pointee
        for index in 0..<frameLength {
            samples[index] = Float(expectedRampSample(startIndex + index)) / 32_768.0
        }
        return buffer
    }

    private func expectedRampSample(_ index: Int) -> Int16 {
        Int16((index % 16_000) - 8_000)
    }

    private func decode(_ frames: [CapturePCM16Pipeline.AudioFrame]) -> [Int16] {
        var samples: [Int16] = []
        for frame in frames {
            frame.pcm.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                for index in 0..<(frame.pcm.count / 2) {
                    let raw = base.advanced(by: index * 2).load(as: UInt16.self)
                    samples.append(Int16(bitPattern: UInt16(littleEndian: raw)))
                }
            }
        }
        return samples
    }
}

private final class CopyResultBox {
    private let lock = NSLock()
    private var value: BoundedPCMQueue.CopyResult = .ignored

    func store(_ result: BoundedPCMQueue.CopyResult) {
        lock.lock()
        value = result
        lock.unlock()
    }

    func load() -> BoundedPCMQueue.CopyResult {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
