import AVFoundation
import Dispatch
import Foundation
import XCTest
@testable import CamMic

final class AudioCaptureQueueTests: XCTestCase {
    func testCaptureQueueHasFixedEightBufferCapacity() {
        let queue = makeQueue(slotCount: 8)
        defer { queue.finish() }
        let source = makeSourceBuffer()

        for index in 0..<8 {
            XCTAssertEqual(queue.copyFromSystemBuffer(source, capturedAtNanoseconds: UInt64(index)), .copied)
        }
        guard case .overrun(let diagnostic) = queue.copyFromSystemBuffer(source, capturedAtNanoseconds: 8) else {
            return XCTFail("The queue should report its first bounded-pool overrun")
        }
        XCTAssertEqual(diagnostic.reason, .noFreeSlot(occupied: 8))
        XCTAssertEqual(diagnostic.bufferedFrames, .some(UInt32(8 * 1024)))
        XCTAssertEqual(queue.copyFromSystemBuffer(source, capturedAtNanoseconds: 9), .ignored)
    }

    func testSingleSystemBufferMayExceedLegacy4096FrameSlotWithExplicitBound() {
        let queue = makeQueue(slotCount: 8, maximumFrames: 16_384, maximumBufferedFrames: 14_400)
        defer { queue.finish() }
        let source = makeSourceBuffer(frameLength: 8192)

        XCTAssertEqual(queue.copyFromSystemBuffer(source, capturedAtNanoseconds: 1), .copied)
        guard let item = queue.take() else { return XCTFail("The copied buffer should be available") }
        queue.release(item.index)
    }

    func testQueueReportsWhenCumulativeAudioDurationExceedsItsBound() {
        let queue = makeQueue(slotCount: 4, maximumFrames: 4096, maximumBufferedFrames: 2048)
        defer { queue.finish() }
        let source = makeSourceBuffer()

        XCTAssertEqual(queue.copyFromSystemBuffer(source, capturedAtNanoseconds: 1), .copied)
        XCTAssertEqual(queue.copyFromSystemBuffer(source, capturedAtNanoseconds: 2), .copied)
        guard case .overrun(let diagnostic) = queue.copyFromSystemBuffer(source, capturedAtNanoseconds: 3) else {
            return XCTFail("The queue should identify its total-frame budget")
        }
        XCTAssertEqual(diagnostic.reason, .bufferedDurationExceeded(current: 2048, incoming: 1024, maximum: 2048))
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

    func testTapCopyDoesNotWaitForOccupiedConsumerStateAndNotifiesOnlyOnce() {
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
        guard case .overrun(let diagnostic) = firstResult.load() else {
            return XCTFail("The first contention must emit the single fatal queue diagnostic")
        }
        XCTAssertEqual(diagnostic.reason, .stateLockContended)
        XCTAssertNil(diagnostic.bufferedFrames, "Locked queue counts must not be read without the lock")
        XCTAssertEqual(secondResult.load(), .ignored, "A single contention failure must not notify again or accept more PCM")
        XCTAssertEqual(queue.bufferedFramesForTesting, 0)
    }

    private func makeQueue(
        slotCount: Int,
        maximumFrames: AVAudioFrameCount = 4096,
        maximumBufferedFrames: AVAudioFrameCount = 65_536
    ) -> BoundedPCMQueue {
        BoundedPCMQueue(
            format: audioFormat(),
            slotCount: slotCount,
            maximumFrames: maximumFrames,
            maximumBufferedFrames: maximumBufferedFrames
        )
    }

    private func makeSourceBuffer(frameLength: AVAudioFrameCount = 1024) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat(), frameCapacity: frameLength)!
        buffer.frameLength = frameLength
        return buffer
    }

    private func audioFormat() -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
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
