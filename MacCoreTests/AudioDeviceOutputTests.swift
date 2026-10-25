import AVFoundation
import CamMicShared
import CoreAudio
import XCTest
@testable import CamMicMacCore

final class AudioDeviceOutputTests: XCTestCase {
    func testRenderLockContentionMutesWithoutAdvancingSequenceAndHasSeparateDiagnostic() throws {
        let output = try AudioDeviceOutput(device: makeDevice())
        defer { output.stopAndClear() }
        try output.enqueue(pcm16LittleEndian: pcm16(value: 8_192), sequence: 73)
        output.markPlaybackActive()

        let acquired = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let holderFinished = DispatchSemaphore(value: 0)
        output.holdRenderLockForTesting(acquired: acquired, release: release, finished: holderFinished)
        guard acquired.wait(timeout: .now() + 5) == .success else {
            release.signal()
            XCTFail("The test thread did not acquire the render state lock")
            return
        }

        let renderReturned = DispatchSemaphore(value: 0)
        let result = FloatArrayBox()
        DispatchQueue.global(qos: .userInitiated).async {
            result.store(output.renderForTesting(frameCount: Int(CamMicFrameCodec.samplesPerFrame)))
            renderReturned.signal()
        }
        let returnedBeforeUnlock = renderReturned.wait(timeout: .now() + 5) == .success
        release.signal()
        XCTAssertEqual(holderFinished.wait(timeout: .now() + 5), .success)
        if !returnedBeforeUnlock {
            _ = renderReturned.wait(timeout: .now() + 5)
        }

        XCTAssertTrue(returnedBeforeUnlock, "Render must return while the producer-side state lock is still held")
        XCTAssertTrue(result.load().allSatisfy { $0 == 0 }, "Contended output must remain silent")
        var metrics = output.metrics
        XCTAssertEqual(metrics.lastConsumed, 0, "A silent contention callback must not consume a packet")
        XCTAssertEqual(metrics.queuedPackets, 1)
        XCTAssertEqual(metrics.renderContentions, 1)
        XCTAssertEqual(metrics.underruns, 0, "Lock contention is not an audio underrun")

        let recovered = output.renderForTesting(frameCount: Int(CamMicFrameCodec.samplesPerFrame))
        XCTAssertEqual(recovered.count, Int(CamMicFrameCodec.samplesPerFrame) * 2)
        XCTAssertTrue(recovered.contains { abs($0) > 0.05 }, "The queued voice samples should render after contention clears")
        for frame in 0..<Int(CamMicFrameCodec.samplesPerFrame) {
            XCTAssertEqual(recovered[frame * 2], recovered[frame * 2 + 1], accuracy: 0.0001)
        }
        metrics = output.metrics
        XCTAssertEqual(metrics.lastConsumed, 73)
        XCTAssertEqual(metrics.queuedPackets, 0)
        XCTAssertEqual(metrics.renderContentions, 1)
    }

    private func makeDevice() -> AudioOutputDevice {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        )!
        return AudioOutputDevice(
            id: AudioDeviceID(1),
            uid: "CamMicTests.Output",
            name: "CamMic Test Output",
            sampleRate: 48_000,
            channelCount: 2,
            format: format.streamDescription.pointee
        )
    }

    private func pcm16(value: Int16) -> Data {
        var payload = Data(count: Int(CamMicFrameCodec.audioPayloadLength))
        payload.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            for index in 0..<Int(CamMicFrameCodec.samplesPerFrame) {
                base.advanced(by: index * 2).storeBytes(of: value.littleEndian, as: Int16.self)
            }
        }
        return payload
    }
}

private final class FloatArrayBox {
    private let lock = NSLock()
    private var value: [Float] = []

    func store(_ samples: [Float]) {
        lock.lock()
        value = samples
        lock.unlock()
    }

    func load() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
