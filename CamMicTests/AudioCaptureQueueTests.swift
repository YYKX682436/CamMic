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
        XCTAssertEqual(queue.copyFromSystemBuffer(source, capturedAtNanoseconds: 8), .overrun)
        XCTAssertEqual(queue.copyFromSystemBuffer(source, capturedAtNanoseconds: 9), .ignored)
    }

    func testPrestartedConsumerDrainsMoreThanPoolCapacityWithoutOverrun() {
        let queue = makeQueue(slotCount: 8)
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

    private func makeQueue(slotCount: Int) -> BoundedPCMQueue {
        BoundedPCMQueue(format: audioFormat(), slotCount: slotCount, maximumFrames: 4096)
    }

    private func makeSourceBuffer() -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat(), frameCapacity: 1024)!
        buffer.frameLength = 1024
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
