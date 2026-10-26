import AppKit
import AVFoundation
import CamMicMacCore
import CamMicShared
import CoreAudio
import Network
import XCTest
@testable import CamMicMac

final class USBAutoConnectionControllerTests: XCTestCase {
    private func device(_ id: String) -> CamMicUSBDevice { CamMicUSBDevice(udid: "00000000-00000000000000000000000000000000" + id) }

    func testOneAlreadyInsertedPhoneStartsUSBAndRemovalDisconnectsImmediately() {
        let phone = device("0001")
        let discovery = FakeUSBDiscovery(initial: [phone])
        let forwarders = FakeUSBForwarderFactory()
        let receiver = FakeUSBReceiver()
        let connected = expectation(description: "USB connection starts")
        receiver.onConnect = { connected.fulfill() }
        let controller = makeController(discovery: discovery, forwarders: forwarders, receiver: receiver)
        controller.setAudioComponentReady(true)
        controller.start()
        wait(for: [connected], timeout: 2)

        XCTAssertEqual(forwarders.created.map(\.deviceID), [phone.udid, phone.udid])
        XCTAssertEqual(forwarders.created.map(\.devicePort), [50889, 50890])
        let disconnected = expectation(description: "removal disconnects")
        receiver.onDisconnect = { disconnected.fulfill() }
        discovery.emit(2, device: phone)
        wait(for: [disconnected], timeout: 2)
        XCTAssertEqual(receiver.disconnectCount, 1)
        receiver.onDisconnect = nil
        controller.shutdown()
    }

    func testDiscoveryRecoversWhenUSBMuxIsTemporarilyUnavailableAtStartup() {
        let phone = device("0001")
        let discovery = FakeUSBDiscovery(initial: [phone], failuresRemaining: 1)
        let receiver = FakeUSBReceiver()
        let connected = expectation(description: "already inserted phone connects after discovery recovers")
        receiver.onConnect = { connected.fulfill() }
        let controller = makeController(
            discovery: discovery,
            forwarders: FakeUSBForwarderFactory(),
            receiver: receiver,
            retryDelays: [0.01]
        )
        controller.setAudioComponentReady(true)
        controller.start()
        wait(for: [connected], timeout: 2)
        XCTAssertEqual(discovery.startCalls, 2)
        controller.shutdown()
    }

    func testMultiplePhonesRequireSelectionUnlessSavedPreferenceMatches() {
        let first = device("0001")
        let second = device("0002")
        let discovery = FakeUSBDiscovery(initial: [first, second])
        let forwarders = FakeUSBForwarderFactory()
        let receiver = FakeUSBReceiver()
        let controller = makeController(
            discovery: discovery,
            forwarders: forwarders,
            receiver: receiver,
            preferred: nil
        )
        let ambiguous = expectation(description: "ambiguous list displayed")
        controller.onDeviceState = { state in
            if state.devices.count == 2 && state.selectedDeviceID == nil { ambiguous.fulfill() }
        }
        controller.setAudioComponentReady(true)
        controller.start()
        wait(for: [ambiguous], timeout: 2)
        XCTAssertTrue(forwarders.created.isEmpty, "CamMic must not randomly choose between phones")

        let connected = expectation(description: "selected phone connects")
        receiver.onConnect = { connected.fulfill() }
        controller.selectDevice(second.udid)
        wait(for: [connected], timeout: 2)
        XCTAssertEqual(forwarders.created.map(\.deviceID), [second.udid, second.udid])
        controller.shutdown()
    }

    func testSavedPhoneIsPreferredWhenSeveralAreConnected() {
        let first = device("0001")
        let second = device("0002")
        let discovery = FakeUSBDiscovery(initial: [first, second])
        let forwarders = FakeUSBForwarderFactory()
        let receiver = FakeUSBReceiver()
        let connected = expectation(description: "saved phone connects")
        receiver.onConnect = { connected.fulfill() }
        let controller = makeController(
            discovery: discovery,
            forwarders: forwarders,
            receiver: receiver,
            preferred: second.udid
        )
        controller.setAudioComponentReady(true)
        controller.start()
        wait(for: [connected], timeout: 2)
        XCTAssertEqual(forwarders.created.map(\.deviceID), [second.udid, second.udid])
        controller.shutdown()
    }

    func testManualStopCancelsRetryUntilTheUserResumes() {
        let phone = device("0001")
        let receiver = FakeUSBReceiver()
        let connected = expectation(description: "initial connection")
        connected.expectedFulfillmentCount = 1
        receiver.onConnect = { connected.fulfill() }
        let controller = makeController(
            discovery: FakeUSBDiscovery(initial: [phone]),
            forwarders: FakeUSBForwarderFactory(),
            receiver: receiver,
            retryDelays: [0.15]
        )
        controller.setAudioComponentReady(true)
        controller.start()
        wait(for: [connected], timeout: 2)

        let retryScheduled = expectation(description: "failure observed")
        let stopped = expectation(description: "manual stop cancels the pending retry")
        controller.onStatus = { status in
            if status == "temporary failure" {
                retryScheduled.fulfill()
                controller.stopByUser()
            } else if status.contains("已停止并静音") {
                stopped.fulfill()
            }
        }
        receiver.failCurrentAttempt("temporary failure")
        wait(for: [retryScheduled, stopped], timeout: 2)
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertEqual(receiver.connectCount, 1)

        let resumed = expectation(description: "explicit resume connects")
        receiver.onConnect = { resumed.fulfill() }
        controller.resumeByUser()
        wait(for: [resumed], timeout: 2)
        XCTAssertEqual(receiver.connectCount, 2)
        controller.shutdown()
    }

    func testRepeatedRemovalAndInsertionCreatesFreshForwarders() {
        let phone = device("0001")
        let discovery = FakeUSBDiscovery(initial: [phone])
        let forwarders = FakeUSBForwarderFactory()
        let receiver = FakeUSBReceiver()
        let firstConnection = expectation(description: "initial USB connection")
        receiver.onConnect = { firstConnection.fulfill() }
        let controller = makeController(discovery: discovery, forwarders: forwarders, receiver: receiver)
        controller.setAudioComponentReady(true)
        controller.start()
        wait(for: [firstConnection], timeout: 2)

        let disconnected = expectation(description: "unplug stops prior session")
        receiver.onDisconnect = { disconnected.fulfill() }
        discovery.emit(2, device: phone)
        wait(for: [disconnected], timeout: 2)
        receiver.onDisconnect = nil
        XCTAssertEqual(forwarders.instances.count, 2)
        XCTAssertTrue(forwarders.instances.allSatisfy(\.stopped))

        let reconnected = expectation(description: "reinsert creates a fresh session")
        receiver.onConnect = { reconnected.fulfill() }
        discovery.emit(1, device: phone)
        wait(for: [reconnected], timeout: 2)
        XCTAssertEqual(receiver.connectCount, 2)
        XCTAssertEqual(forwarders.created.count, 4)
        XCTAssertEqual(Set(forwarders.created.map(\.deviceID)), Set([phone.udid]))
        controller.shutdown()
    }

    func testInitializationTimeoutCanRetryWithoutARequestCountCeiling() {
        let phone = device("0001")
        let receiver = FakeUSBReceiver()
        let initialAttempt = expectation(description: "initial USB attempt")
        receiver.onConnect = { initialAttempt.fulfill() }
        let controller = makeController(
            discovery: FakeUSBDiscovery(initial: [phone]),
            forwarders: FakeUSBForwarderFactory(),
            receiver: receiver,
            retryDelays: [0.01]
        )
        controller.setAudioComponentReady(true)
        controller.start()
        wait(for: [initialAttempt], timeout: 2)
        let retry = expectation(description: "initialization timeout retries")
        receiver.onConnect = { retry.fulfill() }
        receiver.failCurrentAttempt("USB initialization timed out")
        wait(for: [retry], timeout: 2)
        XCTAssertEqual(receiver.connectCount, 2)
        controller.shutdown()
    }

    func testLateFailureFromOldDeviceCannotRestartReplacement() {
        let first = device("0001")
        let second = device("0002")
        let discovery = FakeUSBDiscovery(initial: [first])
        let receiver = FakeUSBReceiver()
        let firstConnect = expectation(description: "first device connects")
        receiver.onConnect = { firstConnect.fulfill() }
        let controller = makeController(
            discovery: discovery,
            forwarders: FakeUSBForwarderFactory(),
            receiver: receiver,
            retryDelays: [0.08]
        )
        controller.setAudioComponentReady(true)
        controller.start()
        wait(for: [firstConnect], timeout: 2)
        let oldAttempt = receiver.tokens[0]

		let replacement = expectation(description: "replacement connects")
		receiver.onConnect = { replacement.fulfill() }
		discovery.emit(2, device: first)
		discovery.emit(1, device: second)
        wait(for: [replacement], timeout: 2)
        receiver.fail(token: oldAttempt, message: "late old failure")
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(receiver.connectCount, 2)
        controller.shutdown()
    }

    func testQueuedUSBEventsCannotReconnectAfterAppShutdown() {
        let phone = device("0001")
        let discovery = FakeUSBDiscovery(initial: [phone])
        let receiver = FakeUSBReceiver()
        let connected = expectation(description: "initial phone connection")
        receiver.onConnect = { connected.fulfill() }
        let controller = makeController(
            discovery: discovery,
            forwarders: FakeUSBForwarderFactory(),
            receiver: receiver
        )
        controller.setAudioComponentReady(true)
        controller.start()
        wait(for: [connected], timeout: 2)
        controller.shutdown()

        let noReconnect = expectation(description: "shutdown suppresses stale discovery callbacks")
        noReconnect.isInverted = true
        receiver.onConnect = { noReconnect.fulfill() }
        discovery.emit(2, device: phone)
        discovery.emit(1, device: phone)
        wait(for: [noReconnect], timeout: 0.15)
        XCTAssertEqual(receiver.connectCount, 1)
    }

    func testMainViewStopResumeKeepsMutePreferenceAndBlocksHotplugWhileStopped() {
        let phone = device("0001")
        let discovery = FakeUSBDiscovery(initial: [phone])
        let factory = FakeMacAudioOutputFactory()
        let receiver = makeProductionPathReceiver(factory: factory)
        let controller = makeProductionPathController(discovery: discovery, receiver: receiver)
        let session = CamMicSessionCoordinator(receiver: receiver, usbController: controller)
        let viewController = onMainThread {
            MacMainViewController(session: session)
        }
        let stopped = expectation(description: "the production stop action reaches the USB controller")
        var stopObserved = false
        let observation = onMainThread {
            session.addObserver { state in
                if state.userStopped && state.status.contains("已停止并静音") && !stopObserved {
                    stopObserved = true
                    stopped.fulfill()
                }
            }
        }
        controller.setAudioComponentReady(true)
        controller.start()

        let initialOutput = factory.waitForCount(1)[0]
        receiver.flushTransportQueueForTesting()
        XCTAssertEqual(initialOutput.muteChanges, [false])

        onMainThread { viewController.stopTapped() }
        wait(for: [stopped], timeout: 2)
        onMainThread { session.removeObserver(observation) }
        receiver.flushTransportQueueForTesting()
        XCTAssertFalse(receiver.isMutedForTesting, "Stopping must not alter the independent mute preference")

        let removedWhileStopped = expectation(description: "the stopped phone was removed")
        controller.onDeviceState = { state in
            if state.devices.isEmpty { removedWhileStopped.fulfill() }
        }
        discovery.emit(2, device: phone)
        wait(for: [removedWhileStopped], timeout: 2)

        let reinsertedWhileStopped = expectation(description: "the stopped phone was reinserted")
        controller.onDeviceState = { state in
            if state.devices == [phone], state.selectedDeviceID == phone.udid { reinsertedWhileStopped.fulfill() }
        }
        discovery.emit(1, device: phone)
        wait(for: [reinsertedWhileStopped], timeout: 2)
        controller.onDeviceState = nil
        onMainThread { session.selectDevice(phone.udid) }
        let selectionProcessed = expectation(description: "device selection is processed while stopped")
        controller.deviceStateSnapshot { _ in selectionProcessed.fulfill() }
        wait(for: [selectionProcessed], timeout: 2)
        XCTAssertEqual(factory.count, 1, "USB insertion must not bypass a manual stop")

        onMainThread { viewController.connectUSBTapped() }
        let resumedOutputs = factory.waitForCount(2)
        receiver.flushTransportQueueForTesting()
        XCTAssertFalse(receiver.isMutedForTesting)
        XCTAssertEqual(resumedOutputs[1].muteChanges, [false], "Explicit resume must create an audible new session")

        controller.shutdown()
        receiver.shutdown()
    }

    func testIndependentMuteSurvivesUSBRemovalAndReconnection() throws {
        let phone = device("0001")
        let discovery = FakeUSBDiscovery(initial: [phone])
        let usbTransport = try USBTransportTestServer()
        defer { usbTransport.stop() }
        let factory = FakeMacAudioOutputFactory()
        let receiver = makeProductionPathReceiver(factory: factory)
        let controller = makeProductionPathController(
            discovery: discovery,
            receiver: receiver,
            forwarders: FakeUSBForwarderFactory(localPorts: [usbTransport.initializationPort, usbTransport.audioPort])
        )
        let session = CamMicSessionCoordinator(receiver: receiver, usbController: controller)
        let viewController = onMainThread {
            MacMainViewController(session: session)
        }
        controller.setAudioComponentReady(true)
        controller.start()

        let initial = factory.waitForCount(1)[0]
        XCTAssertTrue(usbTransport.waitForAudioConnections(1), "Mute must be applied to a live USB audio output")
        receiver.flushTransportQueueForTesting()
        onMainThread { viewController.muteTapped() }
        XCTAssertTrue(receiver.isMutedForTesting)
        XCTAssertEqual(initial.muteChanges.last, true)

        let firstReinsert = expectation(description: "USB reconnect creates a replacement output")
        factory.onCreate = { if $0 == 2 { firstReinsert.fulfill() } }
        discovery.emit(2, device: phone)
        discovery.emit(1, device: phone)
        wait(for: [firstReinsert], timeout: 2)
        XCTAssertTrue(usbTransport.waitForAudioConnections(2))
        factory.onCreate = nil
        receiver.flushTransportQueueForTesting()
        XCTAssertEqual(factory.waitForCount(2)[1].muteChanges, [true], "A user mute must survive automatic reconnection")

        onMainThread { viewController.muteTapped() }
        XCTAssertFalse(receiver.isMutedForTesting)

        let secondReinsert = expectation(description: "unmuted USB reconnect creates a fresh output")
        factory.onCreate = { if $0 == 3 { secondReinsert.fulfill() } }
        discovery.emit(2, device: phone)
        discovery.emit(1, device: phone)
        wait(for: [secondReinsert], timeout: 2)
        XCTAssertTrue(usbTransport.waitForAudioConnections(3))
        factory.onCreate = nil
        receiver.flushTransportQueueForTesting()
        XCTAssertEqual(factory.waitForCount(3)[2].muteChanges, [false], "Cancelling mute must restore the next fresh session")

        controller.shutdown()
        receiver.shutdown()
    }

    func testApplicationSessionIsSharedAcrossWindowRecreationAndMenuActionsOwnFullLifecycle() throws {
        let phone = device("0001")
        let discovery = FakeUSBDiscovery(initial: [phone])
        let usbTransport = try USBTransportTestServer()
        defer { usbTransport.stop() }
        let forwarders = FakeUSBForwarderFactory(localPorts: [usbTransport.initializationPort, usbTransport.audioPort])
        let factory = FakeMacAudioOutputFactory()
        let receiver = makeProductionPathReceiver(factory: factory)
        let controller = USBAutoConnectionController(
            discovery: discovery,
            forwarders: forwarders,
            receiver: receiver,
            eventDelivery: { action in DispatchQueue.main.async(execute: action) },
            preferredDevice: { nil },
            rememberDevice: { _ in },
            retryDelays: [60]
        )
        let session = CamMicSessionCoordinator(receiver: receiver, usbController: controller)
        let appDelegate = AppDelegate(session: session)
        let firstWindowController = onMainThread { MacMainViewController(session: session) }
        let reopenedWindowController = onMainThread { MacMainViewController(session: session) }
        XCTAssertTrue(firstWindowController.sessionForTesting === session)
        XCTAssertTrue(reopenedWindowController.sessionForTesting === session)

        session.setAudioComponentReady(true)
        onMainThread {
            session.start()
            session.start()
        }
        let firstOutput = factory.waitForCount(1)[0]
        XCTAssertTrue(usbTransport.waitForAudioConnections(1), "The menu actions must operate on a live USB audio session")
        receiver.flushTransportQueueForTesting()
        XCTAssertEqual(discovery.startCalls, 1, "Opening or recreating a window must reuse one USB subscription")
        XCTAssertEqual(forwarders.created.count, 2, "The app owns one pair of port forwarders")

        onMainThread { appDelegate.toggleMuteFromMenu() }
        receiver.flushTransportQueueForTesting()
        XCTAssertTrue(receiver.isMutedForTesting)
        XCTAssertEqual(firstOutput.muteChanges.last, true)
        onMainThread { appDelegate.toggleMuteFromMenu() }
        receiver.flushTransportQueueForTesting()
        XCTAssertFalse(receiver.isMutedForTesting)

        let stopped = expectation(description: "the menu connection action stops USB and output")
        var stopObserved = false
        let observation = onMainThread {
            session.addObserver { snapshot in
                if snapshot.userStopped && snapshot.status.contains("已停止并静音") && !stopObserved {
                    stopObserved = true
                    stopped.fulfill()
                }
            }
        }
        onMainThread { appDelegate.toggleConnectionFromMenu() }
        wait(for: [stopped], timeout: 2)
        onMainThread { session.removeObserver(observation) }
        receiver.flushTransportQueueForTesting()
        XCTAssertTrue(firstOutput.isStopped, "Stopping the app session clears and stops CoreAudio output")

        discovery.emit(2, device: phone)
        discovery.emit(1, device: phone)
        let insertionProcessed = expectation(description: "USB insertion is processed while the menu stop is active")
        controller.deviceStateSnapshot { _ in insertionProcessed.fulfill() }
        wait(for: [insertionProcessed], timeout: 2)
        XCTAssertEqual(factory.count, 1, "Hotplug must not override a menu-requested stop")

        let resumed = expectation(description: "the menu connection action resumes explicitly")
        factory.onCreate = { if $0 == 2 { resumed.fulfill() } }
        onMainThread { appDelegate.toggleConnectionFromMenu() }
        wait(for: [resumed], timeout: 2)
        XCTAssertTrue(usbTransport.waitForAudioConnections(2), "Explicit resume must establish a fresh USB audio session")
        factory.onCreate = nil
        receiver.flushTransportQueueForTesting()
        XCTAssertEqual(factory.count, 2)
        XCTAssertEqual(factory.waitForCount(2)[1].muteChanges, [false])

        onMainThread { session.shutdown() }
        XCTAssertTrue(discovery.stopped, "Exit releases the USBMux subscription")
        XCTAssertTrue(forwarders.instances.allSatisfy(\.stopped), "Exit releases every app-owned forwarding port")
        XCTAssertTrue(factory.snapshot.allSatisfy(\.isStopped), "Exit stops all CamMic audio output")
    }

    func testClosingAndReopeningTheMainWindowReusesTheApplicationSession() {
        let discovery = FakeUSBDiscovery(initial: [])
        let forwarders = FakeUSBForwarderFactory()
        let receiver = makeProductionPathReceiver(factory: FakeMacAudioOutputFactory())
        let controller = USBAutoConnectionController(
            discovery: discovery,
            forwarders: forwarders,
            receiver: receiver,
            eventDelivery: { action in DispatchQueue.main.async(execute: action) },
            preferredDevice: { nil },
            rememberDevice: { _ in }
        )
        let session = CamMicSessionCoordinator(receiver: receiver, usbController: controller)
        let delegate = AppDelegate(session: session)
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))

        onMainThread {
            XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        }
        let firstWindow = try! XCTUnwrap(delegate.windowForTesting)
        let firstController = firstWindow.contentViewController as? MacMainViewController
        XCTAssertTrue(firstController?.sessionForTesting === session)
        firstWindow.close()

        onMainThread {
            XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
            session.start()
        }
        XCTAssertTrue(delegate.windowForTesting === firstWindow, "Reopening reuses the retained main window")
        XCTAssertTrue((delegate.windowForTesting?.contentViewController as? MacMainViewController)?.sessionForTesting === session)
        onMainThread { session.start() }
        let discoveryStarted = expectation(description: "the retained application coordinator starts discovery once")
        controller.deviceStateSnapshot { _ in discoveryStarted.fulfill() }
        wait(for: [discoveryStarted], timeout: 2)
        XCTAssertEqual(discovery.startCalls, 1, "Closing and reopening never creates a second USB controller")
        onMainThread {
            delegate.windowForTesting?.close()
            session.shutdown()
        }
        XCTAssertTrue(discovery.stopped)
    }

    func testWakeReconcilesUSBAndDoesNotOverrideManualStop() {
        let phone = device("0001")
        let discovery = FakeUSBDiscovery(initial: [phone])
        let forwarders = FakeUSBForwarderFactory()
        let factory = FakeMacAudioOutputFactory()
        let receiver = makeProductionPathReceiver(factory: factory)
        let controller = USBAutoConnectionController(
            discovery: discovery,
            forwarders: forwarders,
            receiver: receiver,
            eventDelivery: { action in DispatchQueue.main.async(execute: action) },
            preferredDevice: { nil },
            rememberDevice: { _ in },
            retryDelays: [60]
        )
        let session = CamMicSessionCoordinator(receiver: receiver, usbController: controller)
        session.setAudioComponentReady(true)
        onMainThread { session.start() }
        _ = factory.waitForCount(1)

        let afterWake = expectation(description: "wake creates one fresh USB attempt")
        factory.onCreate = { if $0 == 2 { afterWake.fulfill() } }
        onMainThread { session.applicationDidWake() }
        wait(for: [afterWake], timeout: 2)
        factory.onCreate = nil
        XCTAssertEqual(discovery.startCalls, 1, "Wake reuses the one existing USBMux subscription")

        let stopped = expectation(description: "manual stop is visible to app session observers")
        var stopObserved = false
        let observation = onMainThread {
            session.addObserver { snapshot in
                if snapshot.userStopped && snapshot.status.contains("已停止并静音") && !stopObserved {
                    stopObserved = true
                    stopped.fulfill()
                }
            }
        }
        onMainThread { session.stopConnectionByUser() }
        wait(for: [stopped], timeout: 2)
        onMainThread { session.removeObserver(observation) }
        session.applicationDidWake()
        discovery.emit(2, device: phone)
        discovery.emit(1, device: phone)
        let wakeInsertionProcessed = expectation(description: "wake and insertion events remain behind the explicit stop")
        controller.deviceStateSnapshot { _ in wakeInsertionProcessed.fulfill() }
        wait(for: [wakeInsertionProcessed], timeout: 2)
        XCTAssertEqual(factory.count, 2, "Sleep/wake and USB insertion cannot bypass an explicit stop")

        let afterResume = expectation(description: "explicit resume starts a fresh connection")
        factory.onCreate = { if $0 == 3 { afterResume.fulfill() } }
        onMainThread { session.resumeConnectionByUser() }
        wait(for: [afterResume], timeout: 2)
        factory.onCreate = nil
        onMainThread { session.shutdown() }
        XCTAssertTrue(discovery.stopped)
        XCTAssertTrue(forwarders.instances.allSatisfy(\.stopped))
        XCTAssertTrue(factory.snapshot.allSatisfy(\.isStopped))
    }

    private func makeController(
        discovery: FakeUSBDiscovery,
        forwarders: FakeUSBForwarderFactory,
        receiver: FakeUSBReceiver,
        preferred: String? = nil,
        retryDelays: [TimeInterval] = [1, 2, 4, 8]
    ) -> USBAutoConnectionController {
        USBAutoConnectionController(
            discovery: discovery,
            forwarders: forwarders,
            receiver: receiver,
            eventDelivery: { $0() },
            preferredDevice: { preferred },
            rememberDevice: { _ in },
            retryDelays: retryDelays
        )
    }

    private func makeProductionPathController(
        discovery: FakeUSBDiscovery,
        receiver: MacAudioReceiver,
        forwarders: CamMicUSBForwarderCreating = FakeUSBForwarderFactory()
    ) -> USBAutoConnectionController {
        USBAutoConnectionController(
            discovery: discovery,
            forwarders: forwarders,
            receiver: receiver,
            eventDelivery: { $0() },
            preferredDevice: { nil },
            rememberDevice: { _ in },
            retryDelays: [60]
        )
    }

    private func makeProductionPathReceiver(factory: FakeMacAudioOutputFactory) -> MacAudioReceiver {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let endpoints = CamMicAudioEndpoints(
            microphone: AudioInputDevice(
                id: AudioDeviceID(1), uid: "CamMic2ch_UID", name: "CamMic", channelCount: 2,
                format: format.streamDescription.pointee
            ),
            appOutput: AudioOutputDevice(
                id: AudioDeviceID(2), uid: "CamMic2ch_2_UID", name: "CamMicInternalOutput",
                sampleRate: 48_000, channelCount: 2, format: format.streamDescription.pointee
            )
        )
        return MacAudioReceiver(
            eventDelivery: { $0() },
            audioEndpoints: { endpoints },
            audioEndpointsAreCurrent: { _ in true },
            outputFactory: { _ in factory.make() }
        )
    }

    private func onMainThread<T>(_ action: () -> T) -> T {
        if Thread.isMainThread { return action() }
        return DispatchQueue.main.sync(execute: action)
    }
}

private final class FakeUSBDiscovery: CamMicUSBDeviceDiscovering {
    var onDeviceEvent: ((Int32, CamMicUSBDevice) -> Void)?
    private let initial: [CamMicUSBDevice]
    private var failuresRemaining: Int
    private(set) var startCalls = 0
    private(set) var stopped = false

    init(initial: [CamMicUSBDevice], failuresRemaining: Int = 0) {
        self.initial = initial
        self.failuresRemaining = failuresRemaining
    }

    func start() throws -> [CamMicUSBDevice] {
        startCalls += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw FakeDiscoveryError.temporarilyUnavailable
        }
        return initial
    }
    func stop() { stopped = true }
    func emit(_ event: Int32, device: CamMicUSBDevice) { onDeviceEvent?(event, device) }
}

private enum FakeDiscoveryError: LocalizedError {
    case temporarilyUnavailable
    var errorDescription: String? { "USBMux unavailable" }
}

private final class FakeUSBForwarderFactory: CamMicUSBForwarderCreating {
    struct Created {
        let deviceID: String
        let devicePort: UInt16
    }

    private(set) var created: [Created] = []
    private(set) var instances: [FakeUSBForwarder] = []
    private var nextPort: UInt16 = 41_000
    private let localPorts: [UInt16]?

    init(localPorts: [UInt16]? = nil) {
        self.localPorts = localPorts
    }

    func make(device: CamMicUSBDevice, devicePort: UInt16) throws -> CamMicUSBForwarding {
        created.append(Created(deviceID: device.udid, devicePort: devicePort))
        let localPort = localPorts.map { $0[(created.count - 1) % $0.count] } ?? nextPort
        defer { nextPort += 1 }
        let forwarder = FakeUSBForwarder(localPort: localPort)
        instances.append(forwarder)
        return forwarder
    }
}

/// Keeps the production USB receiver on a live loopback path while this test
/// exercises app menu actions. Without peers, Network.framework can reject the
/// synthetic ports immediately and tear down the output before the mute action.
private final class USBTransportTestServer {
    private let queue = DispatchQueue(label: "CamMic.USBTransportTestServer")
    private let condition = NSCondition()
    private let sessionKey = Data(repeating: 0x5A, count: CamMicPairing.sessionKeyLength)
    private var audioConnections: [NWConnection] = []
    private var readyAudioConnections = 0
    private let initializationListener: NWListener
    private let audioListener: NWListener
    private(set) var initializationPort: UInt16 = 0
    private(set) var audioPort: UInt16 = 0

    init() throws {
        initializationListener = try NWListener(using: .tcp, on: .any)
        let audioParameters = CamMicPairing.makeNetworkParameters(
            preSharedKey: sessionKey,
            identity: CamMicPairing.usbTLSPSKIdentity
        )
        audioListener = try NWListener(using: audioParameters, on: .any)

        initializationListener.newConnectionHandler = { [weak self] connection in
            self?.serveInitialization(connection)
        }
        audioListener.newConnectionHandler = { [weak self] connection in
            self?.acceptAudio(connection)
        }
        initializationPort = try Self.start(initializationListener, queue: queue)
        audioPort = try Self.start(audioListener, queue: queue)
    }

    func waitForAudioConnections(_ count: Int, timeout: TimeInterval = 3) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while readyAudioConnections < count, condition.wait(until: deadline) {}
        return readyAudioConnections >= count
    }

    func stop() {
        initializationListener.cancel()
        audioListener.cancel()
        condition.lock()
        let connections = audioConnections
        audioConnections.removeAll()
        condition.unlock()
        connections.forEach { $0.cancel() }
    }

    private static func start(_ listener: NWListener, queue: DispatchQueue) throws -> UInt16 {
        let condition = NSCondition()
        var result: Result<UInt16, Error>?
        listener.stateUpdateHandler = { state in
            condition.lock()
            defer { condition.unlock() }
            switch state {
            case .ready:
                if let port = listener.port?.rawValue { result = .success(port) }
            case .failed(let error):
                result = .failure(error)
            default:
                break
            }
            condition.broadcast()
        }
        listener.start(queue: queue)
        condition.lock()
        let deadline = Date().addingTimeInterval(3)
        while result == nil, condition.wait(until: deadline) {}
        let outcome = result
        condition.unlock()
        guard let outcome = outcome else { throw TestServerError.listenerTimedOut }
        return try outcome.get()
    }

    private func serveInitialization(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { connection.cancel(); return }
            guard case .ready = state else { return }
            connection.receive(
                minimumIncompleteLength: CamMicUSBSessionMaterialCodec.requestLength,
                maximumLength: CamMicUSBSessionMaterialCodec.requestLength
            ) { data, _, complete, error in
                guard error == nil, !complete,
                      let data = data,
                      let nonce = CamMicUSBSessionMaterialCodec.decodeRequest(data),
                      let response = try? CamMicUSBSessionMaterialCodec.encodeResponse(
                        sessionKey: self.sessionKey,
                        nonce: nonce
                      ) else {
                    connection.cancel()
                    return
                }
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        connection.start(queue: queue)
    }

    private func acceptAudio(_ connection: NWConnection) {
        condition.lock()
        audioConnections.append(connection)
        condition.unlock()
        connection.stateUpdateHandler = { [weak self] state in
            guard case .ready = state, let self = self else { return }
            self.condition.lock()
            self.readyAudioConnections += 1
            self.condition.broadcast()
            self.condition.unlock()
        }
        connection.start(queue: queue)
    }

    private enum TestServerError: Error {
        case listenerTimedOut
    }
}

private final class FakeUSBForwarder: CamMicUSBForwarding {
    let localPort: UInt16
    private(set) var stopped = false
    init(localPort: UInt16) { self.localPort = localPort }
    func stop() { stopped = true }
}

private final class FakeUSBReceiver: CamMicUSBReceiving {
    var onUSBAttemptEnded: ((UUID, String) -> Void)?
    var onUSBHandshakeReady: ((UUID) -> Void)?
    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?
    private(set) var tokens: [UUID] = []
    private(set) var disconnectCount = 0
    var connectCount: Int { tokens.count }

    func connectUSB(initializationPort: UInt16, audioPort: UInt16) -> UUID {
        let token = UUID()
        tokens.append(token)
        onConnect?()
        return token
    }

    func disconnect(statusMessage: String) {
        disconnectCount += 1
        onDisconnect?()
    }

    func failCurrentAttempt(_ message: String) {
        guard let token = tokens.last else { return }
        onUSBAttemptEnded?(token, message)
    }

    func fail(token: UUID, message: String) { onUSBAttemptEnded?(token, message) }
}

private final class FakeMacAudioOutputFactory {
    private let condition = NSCondition()
    private(set) var outputs: [FakeMacAudioOutput] = []
    var onCreate: ((Int) -> Void)?

    var snapshot: [FakeMacAudioOutput] {
        condition.lock()
        defer { condition.unlock() }
        return outputs
    }

    var count: Int {
        condition.lock()
        defer { condition.unlock() }
        return outputs.count
    }

    func make() -> FakeMacAudioOutput {
        condition.lock()
        let output = FakeMacAudioOutput()
        outputs.append(output)
        let count = outputs.count
        let callback = onCreate
        condition.broadcast()
        condition.unlock()
        callback?(count)
        return output
    }

    func waitForCount(_ count: Int, timeout: TimeInterval = 3) -> [FakeMacAudioOutput] {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while outputs.count < count, condition.wait(until: deadline) {}
        return outputs
    }
}

private final class FakeMacAudioOutput: MacAudioOutputControlling {
    private let lock = NSLock()
    private var muted = false
    private var queuedPackets = 0
    private var consumed: UInt64 = 0
    private var muteHistory: [Bool] = []
    private var didStop = false

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didStop
    }

    var muteChanges: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return muteHistory
    }

    var metrics: (queuedFrames: Int, queuedPackets: Int, lastConsumed: UInt64, underruns: UInt64, renderContentions: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (queuedPackets, queuedPackets, consumed, 0, 0)
    }

    func start() throws {}
    func stopAndClear() {
        lock.lock()
        didStop = true
        queuedPackets = 0
        consumed = 0
        lock.unlock()
    }
    func setMuted(_ muted: Bool) {
        lock.lock()
        self.muted = muted
        muteHistory.append(muted)
        if muted { queuedPackets = 0 }
        lock.unlock()
    }
    func enqueue(pcm16LittleEndian: Data, sequence: UInt64) throws {
        lock.lock()
        if muted { consumed = sequence }
        else { queuedPackets += 1 }
        lock.unlock()
    }
    func markPlaybackActive() {}
}
