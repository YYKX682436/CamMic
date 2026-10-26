import XCTest
import Network
import CamMicShared
@testable import CamMicMac

final class MacAudioReceiverTests: XCTestCase {
    private func initialization() -> NWConnection {
        NWConnection(host: .ipv4(.loopback), port: 50889, using: .tcp)
    }

    private func metrics(bytes: UInt64) -> MacAudioReceiver.Metrics {
        .init(queuedPackets: 0, queuedFrames: 0, outputSampleRate: 48000,
              receivedPackets: 1, receivedPCMBytes: bytes, receivedPCMRMS: 0.1,
              receivedPCMPeak: 0.2, protocolErrors: 0, underrunCallbacks: 0,
              renderContentions: 0, lastConsumedSequence: 1)
    }

    func testLateKeyCompletionAndCancellationCannotReplaceNewUSBInitialization() throws {
        let receiver = MacAudioReceiver(eventDelivery: { _ in })
        let oldGeneration = UUID(), newGeneration = UUID()
        let old = initialization(), current = initialization()
        receiver.installUSBInitializationForTesting(old, generation: oldGeneration)
        receiver.disconnect()
        receiver.flushTransportQueueForTesting()
        receiver.installUSBInitializationForTesting(current, generation: newGeneration)

        receiver.completeUSBInitializationForTesting(key: try CamMicPairing.newSessionKey(),
                                                   generation: oldGeneration, initialization: old)
        receiver.endSessionForTesting(generation: oldGeneration)
        XCTAssertTrue(receiver.ownsUSBInitializationForTesting(current))
        XCTAssertFalse(receiver.audioConnectionPresentForTesting,
                       "An old init callback must never install its key on a new TLS connection")

        // Even a callback carrying the current generation needs the exact current connection.
        receiver.completeUSBInitializationForTesting(key: try CamMicPairing.newSessionKey(),
                                                   generation: newGeneration, initialization: old)
        XCTAssertTrue(receiver.ownsUSBInitializationForTesting(current))
        XCTAssertFalse(receiver.audioConnectionPresentForTesting)
        receiver.shutdown()
    }

    func testDisconnectDetachesInitializationBeforeLateCancellation() {
        var deliveries: [() -> Void] = []
        let receiver = MacAudioReceiver(eventDelivery: { deliveries.append($0) })
        let generation = UUID()
        let connection = initialization()
        connection.stateUpdateHandler = { _ in XCTFail("Detached init callbacks must be removed") }
        receiver.installUSBInitializationForTesting(connection, generation: generation)
        receiver.disconnect()
        receiver.flushTransportQueueForTesting()
        XCTAssertNil(connection.stateUpdateHandler)
        XCTAssertFalse(receiver.ownsUSBInitializationForTesting(connection))
        receiver.endSessionForTesting(generation: generation)
        XCTAssertFalse(receiver.audioConnectionPresentForTesting)
        receiver.shutdown()
    }

    func testDelayedOldStatusAndPCMMetricDeliveryCannotOverwriteReplacement() {
        var deliveries: [() -> Void] = []
        var statuses: [String] = []
        var byteCounts: [UInt64] = []
        let receiver = MacAudioReceiver(eventDelivery: { deliveries.append($0) })
        receiver.onStatus = { statuses.append($0) }
        receiver.onMetrics = { byteCounts.append($0.receivedPCMBytes) }
        let old = UUID(), current = UUID()
        receiver.installUSBInitializationForTesting(initialization(), generation: old)
        receiver.publishStatusForTesting("old", generation: old)
        receiver.publishMetricsForTesting(metrics(bytes: 11), generation: old)
        receiver.installUSBInitializationForTesting(initialization(), generation: current)
        receiver.publishStatusForTesting("current", generation: current)
        receiver.publishMetricsForTesting(metrics(bytes: 22), generation: current)

        deliveries.removeFirst()()
        deliveries.removeFirst()()
        XCTAssertEqual(receiver.metricsPendingGenerationForTesting, current,
                       "An old UI callback cannot clear the replacement's pending PCM metrics")
        deliveries.forEach { $0() }
        XCTAssertEqual(statuses, ["current"])
        XCTAssertEqual(byteCounts, [22])
        XCTAssertNil(receiver.metricsPendingGenerationForTesting)
        receiver.shutdown()
    }

    func testTLSWaitingCancelsUSBAndLateOldWaitingCannotClearReplacement() {
        let receiver = MacAudioReceiver(eventDelivery: { _ in })
        let old = UUID(), current = UUID()
        let oldAudio = initialization(), currentAudio = initialization()
        oldAudio.stateUpdateHandler = { _ in }
        receiver.installUSBAudioForTesting(oldAudio, generation: old)
        receiver.deliverUSBAudioStateForTesting(.waiting(.tls(-9820)), audio: oldAudio, generation: old)
        XCTAssertFalse(receiver.audioConnectionPresentForTesting)
        XCTAssertNil(oldAudio.stateUpdateHandler)

        receiver.installUSBAudioForTesting(currentAudio, generation: current)
        receiver.deliverUSBAudioStateForTesting(.waiting(.tls(-9820)), audio: oldAudio, generation: old)
        receiver.deliverUSBAudioStateForTesting(.cancelled, audio: oldAudio, generation: old)
        XCTAssertTrue(receiver.audioConnectionPresentForTesting)
        receiver.shutdown()
    }

    func testAcknowledgementUsesFreshSessionAndFirstConsumedSequence() throws {
        let sessionID = Data(repeating: 0xA7, count: 16)
        let encoded = try MacAudioReceiver.encodeAcknowledgement(sessionID: sessionID, consumedSequence: 1)
        var decoder = CamMicFrameDecoder()
        let decoded = try decoder.append(encoded)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].kind, .acknowledgement)
        XCTAssertEqual(decoded[0].sessionID, sessionID)
        XCTAssertEqual(decoded[0].sequence, 1)
    }
}
