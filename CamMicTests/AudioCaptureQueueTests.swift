import AVFoundation
import Dispatch
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
        XCTAssertEqual(diagnostic.bufferedFrames, 8 * 1024)
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
}
