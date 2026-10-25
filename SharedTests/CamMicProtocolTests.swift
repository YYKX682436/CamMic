import XCTest
@testable import CamMicShared

final class CamMicProtocolTests: XCTestCase {
    private let firstID = Data(repeating: 0x11, count: 16)
    private let secondID = Data(repeating: 0x22, count: 16)

    func testDecoderHandlesSplitHeaderAndCoalescedFrames() throws {
        let hello = CamMicFrame(kind: .hello, sessionID: firstID, payload: Data(repeating: 0, count: 12))
        let ready = CamMicFrame(kind: .ready, sessionID: firstID)
        let joined = try CamMicFrameCodec.encode(hello) + CamMicFrameCodec.encode(ready)
        var decoder = CamMicFrameDecoder()

        XCTAssertTrue(try decoder.append(joined.prefix(9)).isEmpty)
        XCTAssertEqual(try decoder.append(joined.dropFirst(9)), [hello, ready])
    }

    func testDecoderRejectsOversizedDeclaredPayloadBeforeWaitingForBody() throws {
        var bytes = try CamMicFrameCodec.encode(
            CamMicFrame(kind: .ready, sessionID: firstID)
        )
        bytes[32] = 0x00
        bytes[33] = 0x00
        bytes[34] = 0x07
        bytes[35] = 0x81
        var decoder = CamMicFrameDecoder()
        XCTAssertThrowsError(try decoder.append(bytes)) {
            XCTAssertEqual($0 as? CamMicProtocolError, .invalidPayloadLength)
        }
    }

    func testSessionAndSequenceRejectOldSessionAndGaps() throws {
        var receive = try CamMicReceiveSequence(sessionID: firstID)
        let payload = Data(repeating: 0, count: CamMicFrameCodec.audioPayloadLength)
        XCTAssertThrowsError(try receive.accept(CamMicFrame(kind: .audio, sessionID: secondID, sequence: 1, payload: payload))) {
            XCTAssertEqual($0 as? CamMicProtocolError, .wrongSession)
        }
        XCTAssertThrowsError(try receive.accept(CamMicFrame(kind: .audio, sessionID: firstID, sequence: 2, payload: payload))) {
            XCTAssertEqual($0 as? CamMicProtocolError, .invalidSequence)
        }
        try receive.accept(CamMicFrame(kind: .audio, sessionID: firstID, sequence: 1, payload: payload))
        XCTAssertEqual(receive.lastReceived, 1)
    }

    func testAcknowledgementWindowIsBoundedAndCumulative() throws {
        let window = CamMicAcknowledgementWindow(maximumInFlight: 3)
        XCTAssertEqual(window.tryAcquireNextSequence(), 1)
        XCTAssertEqual(window.tryAcquireNextSequence(), 2)
        XCTAssertEqual(window.tryAcquireNextSequence(), 3)
        XCTAssertNil(window.tryAcquireNextSequence())
        XCTAssertThrowsError(try window.acknowledge(0))
        try window.acknowledge(2)
        XCTAssertEqual(window.inFlightCount, 1)
        XCTAssertEqual(window.tryAcquireNextSequence(), 4)
        XCTAssertThrowsError(try window.acknowledge(5))
        window.stop()
        XCTAssertNil(window.tryAcquireNextSequence())
    }

    func testPendingAudioBufferKeepsNewestFramesDuring500MillisecondACKStall() {
        let pending = CamMicPendingAudioBuffer(maximumPackets: 8)

        for index in 0..<8 {
            XCTAssertEqual(pending.enqueue(
                capturedAtNanoseconds: UInt64(index),
                payload: Data(repeating: UInt8(index), count: CamMicFrameCodec.audioPayloadLength)
            ), 0)
        }

        // 25 packets represent 500 ms at the 20 ms transport frame interval.
        for index in 8..<33 {
            XCTAssertEqual(pending.enqueue(
                capturedAtNanoseconds: UInt64(index),
                payload: Data(repeating: UInt8(index), count: CamMicFrameCodec.audioPayloadLength)
            ), 1)
        }

        XCTAssertEqual(pending.snapshot.queuedPackets, 8)
        XCTAssertEqual(pending.snapshot.droppedPackets, 25)
        XCTAssertEqual((0..<8).compactMap { _ in pending.dequeue()?.capturedAtNanoseconds }, Array(25..<33).map(UInt64.init))
        XCTAssertEqual(pending.snapshot.queuedPackets, 0)
    }

    func testPendingAudioBufferDropsAllOldSessionPacketsWhenCleared() {
        let pending = CamMicPendingAudioBuffer(maximumPackets: 8)
        for index in 0..<8 {
            _ = pending.enqueue(
                capturedAtNanoseconds: UInt64(index),
                payload: Data(repeating: 0, count: CamMicFrameCodec.audioPayloadLength)
            )
        }

        XCTAssertEqual(pending.clear(), 8)
        XCTAssertEqual(pending.snapshot.queuedPackets, 0)
        XCTAssertNil(pending.dequeue())
    }

    func testNonblockingSequenceAllocationPreservesContinuityAfterWindowFrees() throws {
        let window = CamMicAcknowledgementWindow(maximumInFlight: 8)
        for sequence in 1...8 {
            XCTAssertEqual(window.tryAcquireNextSequence(), UInt64(sequence))
        }

        XCTAssertNil(window.tryAcquireNextSequence(), "A full ACK window must return immediately")
        try window.acknowledge(8)
        XCTAssertEqual(window.tryAcquireNextSequence(), 9, "Skipped audio must not reserve a sequence number")
        window.stop()
    }
}
