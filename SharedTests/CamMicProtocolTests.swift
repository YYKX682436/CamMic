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
        XCTAssertEqual(window.acquireNextSequence(timeout: 0), 1)
        XCTAssertEqual(window.acquireNextSequence(timeout: 0), 2)
        XCTAssertEqual(window.acquireNextSequence(timeout: 0), 3)
        XCTAssertNil(window.acquireNextSequence(timeout: 0))
        XCTAssertThrowsError(try window.acknowledge(0))
        try window.acknowledge(2)
        XCTAssertEqual(window.inFlightCount, 1)
        XCTAssertEqual(window.acquireNextSequence(timeout: 0), 4)
        XCTAssertThrowsError(try window.acknowledge(5))
        window.stop()
        XCTAssertNil(window.acquireNextSequence(timeout: 0))
    }
}
