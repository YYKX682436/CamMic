import Foundation
import Network
import UIKit
import XCTest
@testable import CamMic

final class AudioLinkServerTests: XCTestCase {
    func testDelayedOldListenerFailureCannotStopOrOverwriteNewCapture() {
        var scheduledDeliveries: [() -> Void] = []
        let server = AudioLinkServer(eventDelivery: { scheduledDeliveries.append($0) })
        let capture = AudioCapture()
        let controller = CaptureViewController(capture: capture, link: server)
        controller.loadViewIfNeeded()

        let oldGeneration = UUID()
        let newGeneration = UUID()
        controller.setCaptureGenerationForTesting(oldGeneration)
        server.setListenerGenerationForTesting(oldGeneration)
        server.failListenerForTesting("旧监听错误", generation: oldGeneration)
        XCTAssertEqual(scheduledDeliveries.count, 1)

        controller.setCaptureGenerationForTesting(newGeneration)
        server.setListenerGenerationForTesting(newGeneration)
        scheduledDeliveries.removeFirst()()
        controller.consumeAudioLinkEvent(AudioLinkServer.Event(
            listenerGeneration: oldGeneration,
            kind: .listenerFailure,
            message: "迟到的旧会话错误"
        ))
        XCTAssertTrue(capture.isCapturing)
        XCTAssertNotEqual(statusText(in: controller.view), "迟到的旧会话错误")

        server.failListenerForTesting("当前监听错误", generation: newGeneration)
        XCTAssertEqual(scheduledDeliveries.count, 1)
        scheduledDeliveries.removeFirst()()
        XCTAssertFalse(capture.isCapturing, "A fatal event for the active listener must stop capture")
        XCTAssertEqual(statusText(in: controller.view), "当前监听错误")
    }

    func testLateStatusFromOldConnectionCannotOverwriteReplacementSession() {
        var scheduledDeliveries: [() -> Void] = []
        let server = AudioLinkServer(eventDelivery: { scheduledDeliveries.append($0) })
        let capture = AudioCapture()
        let controller = CaptureViewController(capture: capture, link: server)
        controller.loadViewIfNeeded()

        let generation = UUID()
        controller.setCaptureGenerationForTesting(generation)
        server.setListenerGenerationForTesting(generation)
        controller.consumeAudioLinkEvent(AudioLinkServer.Event(
            listenerGeneration: generation,
            kind: .status,
            message: "新会话当前状态"
        ))

        let oldConnectionEpoch = server.statusEpochForTesting
        server.publishStatusForTesting("旧连接迟到状态", generation: generation, statusEpoch: oldConnectionEpoch)
        let newConnectionEpoch = server.advanceStatusEpochForTesting()
        scheduledDeliveries.removeFirst()()
        XCTAssertEqual(statusText(in: controller.view), "新会话当前状态")

        server.publishStatusForTesting("替换连接当前状态", generation: generation, statusEpoch: newConnectionEpoch)
        scheduledDeliveries.removeFirst()()
        XCTAssertEqual(statusText(in: controller.view), "替换连接当前状态")
        XCTAssertTrue(capture.isCapturing)
    }

    func testNormalEOFReceiveCompletionClearsHandlerCancelsConnectionAndWakesACKWaiter() {
        let cancellations = CancellationCounter()
        let server = AudioLinkServer(
            eventDelivery: { _ in },
            cancelConnection: { connection in
                cancellations.increment()
                connection.cancel()
            }
        )
        let listenerGeneration = UUID()
        let connectionToken = UUID()
        let connection = makeConnection()
        connection.stateUpdateHandler = { _ in }
        let window = CamMicAcknowledgementWindow(maximumInFlight: 1)
        XCTAssertEqual(window.acquireNextSequence(timeout: 0), 1)

        let waiterStarted = DispatchSemaphore(value: 0)
        let waiterReturned = DispatchSemaphore(value: 0)
        let waiterResult = OptionalSequenceBox()
        DispatchQueue.global(qos: .userInitiated).async {
            waiterStarted.signal()
            waiterResult.store(window.acquireNextSequence(timeout: 30))
            waiterReturned.signal()
        }
        XCTAssertEqual(waiterStarted.wait(timeout: .now() + 5), .success)
        server.installConnectionForTesting(
            connection,
            listenerGeneration: listenerGeneration,
            connectionToken: connectionToken,
            window: window
        )

        server.receiveEOFForTesting(token: connectionToken)

        XCTAssertNil(connection.stateUpdateHandler)
        XCTAssertEqual(cancellations.value, 1)
        XCTAssertNil(server.activeConnectionTokenForTesting)
        XCTAssertEqual(waiterReturned.wait(timeout: .now() + 5), .success)
        XCTAssertNil(waiterResult.load(), "Teardown must wake a sender blocked on the ACK window")
        server.receiveEOFForTesting(token: connectionToken)
        XCTAssertEqual(cancellations.value, 1, "Repeated EOF cleanup must be harmless")
    }

    func testLateOldConnectionCallbackCannotClearReplacementAndReceiveErrorUsesCleanup() {
        let cancellations = CancellationCounter()
        let server = AudioLinkServer(
            eventDelivery: { _ in },
            cancelConnection: { connection in
                cancellations.increment()
                connection.cancel()
            }
        )
        let listenerGeneration = UUID()
        let oldToken = UUID()
        let oldConnection = makeConnection()
        oldConnection.stateUpdateHandler = { _ in }
        server.installConnectionForTesting(
            oldConnection,
            listenerGeneration: listenerGeneration,
            connectionToken: oldToken,
            window: CamMicAcknowledgementWindow(maximumInFlight: 2)
        )
        server.receiveEOFForTesting(token: oldToken)

        let newToken = UUID()
        let newConnection = makeConnection()
        newConnection.stateUpdateHandler = { _ in }
        let newWindow = CamMicAcknowledgementWindow(maximumInFlight: 2)
        server.installConnectionForTesting(
            newConnection,
            listenerGeneration: listenerGeneration,
            connectionToken: newToken,
            window: newWindow
        )

        server.receiveEOFForTesting(token: oldToken)
        XCTAssertEqual(cancellations.value, 1)
        XCTAssertEqual(server.activeConnectionTokenForTesting, newToken)
        XCTAssertNotNil(newConnection.stateUpdateHandler)
        XCTAssertEqual(newWindow.acquireNextSequence(timeout: 0), 1, "The late callback must not stop the new ACK window")

        server.failConnectionForTesting(token: newToken)
        XCTAssertEqual(cancellations.value, 2)
        XCTAssertNil(newConnection.stateUpdateHandler)
        XCTAssertNil(server.activeConnectionTokenForTesting)
    }

    func testExplicitStopUsesConnectionTeardownAndCanBeRepeated() {
        let cancellations = CancellationCounter()
        let server = AudioLinkServer(
            eventDelivery: { _ in },
            cancelConnection: { connection in
                cancellations.increment()
                connection.cancel()
            }
        )
        let connection = makeConnection()
        connection.stateUpdateHandler = { _ in }
        let window = CamMicAcknowledgementWindow(maximumInFlight: 1)
        XCTAssertEqual(window.acquireNextSequence(timeout: 0), 1)
        server.installConnectionForTesting(
            connection,
            listenerGeneration: UUID(),
            connectionToken: UUID(),
            window: window
        )

        server.stop()
        server.stop()

        XCTAssertNil(connection.stateUpdateHandler)
        XCTAssertEqual(cancellations.value, 1)
        XCTAssertNil(window.acquireNextSequence(timeout: 0))
    }

    private func makeConnection() -> NWConnection {
        NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: 50888)!, using: .tcp)
    }

    private func statusText(in view: UIView) -> String? {
        if view.accessibilityIdentifier == "capture.status" {
            return (view as? UILabel)?.text
        }
        for child in view.subviews {
            if let text = statusText(in: child) { return text }
        }
        return nil
    }
}

private final class CancellationCounter {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private final class OptionalSequenceBox {
    private let lock = NSLock()
    private var value: UInt64?

    func store(_ result: UInt64?) {
        lock.lock()
        value = result
        lock.unlock()
    }

    func load() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
