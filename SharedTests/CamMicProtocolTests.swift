import XCTest
import Network
import Security
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

    func testUSBSessionMaterialUsesHighEntropyLengthAndStrictWireFraming() throws {
        let firstKey = try CamMicPairing.newSessionKey()
        let secondKey = try CamMicPairing.newSessionKey()
        XCTAssertEqual(firstKey.count, 32)
        XCTAssertEqual(secondKey.count, 32)
        XCTAssertFalse(firstKey == secondKey, "A new capture must receive fresh key material")

        let request = try CamMicUSBSessionMaterialCodec.makeRequest()
        XCTAssertEqual(CamMicUSBSessionMaterialCodec.decodeRequest(request.message), request.nonce)
        XCTAssertNil(CamMicUSBSessionMaterialCodec.decodeRequest(Data([0x43, 0x4D, 0x49, 0x51, 0x00, 0x02])))
        let response = try CamMicUSBSessionMaterialCodec.encodeResponse(sessionKey: firstKey, nonce: request.nonce)
        XCTAssertEqual(response.count, CamMicUSBSessionMaterialCodec.responseLength)
        XCTAssertTrue(try CamMicUSBSessionMaterialCodec.decodeResponse(response, expectedNonce: request.nonce) == firstKey,
                      "The response decoder must recover the exact session key")
        XCTAssertThrowsError(try CamMicUSBSessionMaterialCodec.decodeResponse(response.dropLast(), expectedNonce: request.nonce))
        XCTAssertThrowsError(try CamMicUSBSessionMaterialCodec.decodeResponse(response, expectedNonce: secondKey.prefix(16))) {
            XCTAssertEqual($0 as? CamMicProtocolError, .wrongSession)
        }
        var unsupported = response
        unsupported[5] = 2
        XCTAssertThrowsError(try CamMicUSBSessionMaterialCodec.decodeResponse(unsupported, expectedNonce: request.nonce)) {
            XCTAssertEqual($0 as? CamMicProtocolError, .unsupportedVersion)
        }
    }

    func testUSBInitializationRateLimitRecoversAndDoesNotHaveALifetimeRequestCap() {
        var limiter = CamMicUSBInitializationRateLimiter(minimumIntervalNanoseconds: 250_000_000)
        for request in 0..<24 {
            XCTAssertTrue(limiter.accept(nowNanoseconds: UInt64(request) * 250_000_000))
        }
        XCTAssertFalse(limiter.accept(nowNanoseconds: 24 * 250_000_000 - 1))
        XCTAssertTrue(limiter.accept(nowNanoseconds: 24 * 250_000_000))
        limiter.reset()
        XCTAssertTrue(limiter.accept(nowNanoseconds: 1))
    }

    func testTLSPSKAcceptsCurrentUSBKeyAndRejectsWrongAndPriorSessionKeys() throws {
        let priorSessionKey = try CamMicPairing.newSessionKey()
        let currentKey = try CamMicPairing.newSessionKey()
        let wrongKey = try CamMicPairing.newSessionKey()
        let networkQueue = DispatchQueue(label: "CamMicSharedTests.usb-psk", attributes: .concurrent)
        let challenge = Data("CMIC".utf8)
        let response = Data("OKAY".utf8)
        let pskCipherSuites: Set<UInt16> = [
            0x002C, 0x008A, 0x008B, 0x008C, 0x008D,
            0x00A8, 0x00A9, 0x00AE, 0x00AF, 0x00B0, 0x00B1,
            0xCCAB
        ]
        enum AttemptOutcome: Equatable {
            case encryptedEcho
            case serverRejectedPSK
            case unexpectedFailure
        }

        func attempt(key: Data, identity: Data = CamMicPairing.usbTLSPSKIdentity,
                     shouldSucceed: Bool, file: StaticString = #filePath, line: UInt = #line) {
            // A fresh listener per key avoids carrying Network.framework listener
            // connection state from a successful PSK session into a rejection case.
            let listener = try! NWListener(
                using: CamMicPairing.makeNetworkParameters(
                    preSharedKey: currentKey,
                    identity: CamMicPairing.usbTLSPSKIdentity
                ),
                on: NWEndpoint.Port(rawValue: 0)!
            )
            let listenerReady = expectation(description: "isolated TLS-PSK listener is ready")
            let exchangeCompleted = expectation(description: shouldSucceed ? "authenticated encrypted echo" : "unauthenticated PSK rejected")
            let resultLock = NSLock()
            var outcome: AttemptOutcome?
            var completed = false
            var serverAccepted = false
            func finish(_ result: AttemptOutcome) {
                resultLock.lock()
                defer { resultLock.unlock() }
                guard !completed else { return }
                completed = true
                outcome = result
                exchangeCompleted.fulfill()
            }

            func recordServerAccepted() {
                resultLock.lock()
                serverAccepted = true
                resultLock.unlock()
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listenerReady.fulfill()
                case .failed:
                    finish(.unexpectedFailure)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { connection in
                recordServerAccepted()
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.receive(minimumIncompleteLength: challenge.count, maximumLength: challenge.count) { data, _, _, error in
                            guard error == nil, data == challenge else {
                                finish(.unexpectedFailure)
                                return
                            }
                            connection.send(content: response, completion: .contentProcessed { error in
                                if error != nil { finish(.unexpectedFailure) }
                            })
                        }
                    case .failed:
                        finish(.serverRejectedPSK)
                    default:
                        break
                    }
                }
                connection.start(queue: networkQueue)
            }
            listener.start(queue: networkQueue)
            wait(for: [listenerReady], timeout: 5)
            guard let port = listener.port else {
                XCTFail("TLS-PSK listener did not publish its bound port", file: file, line: line)
                listener.cancel()
                return
            }

            let client = NWConnection(
                host: .ipv4(.loopback),
                port: port,
                using: CamMicPairing.makeNetworkParameters(
                    preSharedKey: key,
                    identity: identity
                )
            )
            client.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let tls = client.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata
                    let suite = tls.map { sec_protocol_metadata_get_negotiated_tls_ciphersuite($0.securityProtocolMetadata).rawValue }
                    guard let suite = suite, pskCipherSuites.contains(suite) else {
                        finish(.unexpectedFailure)
                        return
                    }
                    client.send(content: challenge, completion: .contentProcessed { error in
                        guard error == nil else {
                            finish(.unexpectedFailure)
                            return
                        }
                        client.receive(minimumIncompleteLength: response.count, maximumLength: response.count) { data, _, _, error in
                            finish(error == nil && data == response ? .encryptedEcho : .unexpectedFailure)
                        }
                    })
                case .failed:
                    resultLock.lock()
                    let reachedServer = serverAccepted
                    resultLock.unlock()
                    finish(reachedServer ? .serverRejectedPSK : .unexpectedFailure)
                default:
                    break
                }
            }
            client.start(queue: networkQueue)
            wait(for: [exchangeCompleted], timeout: 5)
            resultLock.lock()
            let actualOutcome = outcome
            resultLock.unlock()
            client.stateUpdateHandler = nil
            client.cancel()
            listener.cancel()
            XCTAssertEqual(
                actualOutcome,
                shouldSucceed ? .encryptedEcho : .serverRejectedPSK,
                file: file,
                line: line
            )
        }

        attempt(key: currentKey, shouldSucceed: true)
        attempt(key: wrongKey, shouldSucceed: false)
        attempt(key: priorSessionKey, shouldSucceed: false)
        attempt(key: currentKey, identity: Data("CamMic-invalid-test-identity".utf8), shouldSucceed: false)
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
