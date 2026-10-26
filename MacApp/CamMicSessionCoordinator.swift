import AppKit
import Foundation

/// Application-owned connection session shared by the window and menu bar.
/// Closing a window only detaches its presentation; this coordinator remains
/// responsible for USB discovery, forwarding, receive output, and shutdown.
final class CamMicSessionCoordinator {
    struct Snapshot {
        let status: String
        let deviceState: USBAutoConnectionController.DeviceState
        let isMuted: Bool
        let userStopped: Bool
        let metrics: MacAudioReceiver.Metrics?
    }

    let receiver: MacAudioReceiver
    let usbController: USBAutoConnectionController

    private let eventDelivery: (@escaping () -> Void) -> Void
    private var observers: [UUID: (Snapshot) -> Void] = [:]
    private var wakeObserver: NSObjectProtocol?
    private var started = false
    private var isShutdown = false
    private var status = "等待 iPhone。请在手机上启动 CamMic 采音，再插入 USB。"
    private var deviceState = USBAutoConnectionController.DeviceState(devices: [], selectedDeviceID: nil)
    private var isMuted = false
    private var userStopped = false
    private var metrics: MacAudioReceiver.Metrics?

    init(
        receiver: MacAudioReceiver? = nil,
        usbController: USBAutoConnectionController? = nil,
        eventDelivery: @escaping (@escaping () -> Void) -> Void = { action in
            DispatchQueue.main.async(execute: action)
        }
    ) {
        let activeReceiver = receiver ?? MacAudioReceiver()
        self.receiver = activeReceiver
        self.usbController = usbController ?? USBAutoConnectionController(receiver: activeReceiver)
        self.eventDelivery = eventDelivery

        activeReceiver.onStatus = { [weak self] message in
            self?.update { $0.status = message }
        }
        activeReceiver.onMuteState = { [weak self] muted in
            self?.update { $0.isMuted = muted }
        }
        activeReceiver.onMetrics = { [weak self] metrics in
            self?.update { $0.metrics = metrics }
        }
        self.usbController.onStatus = { [weak self] message in
            self?.update { $0.status = message }
        }
        self.usbController.onDeviceState = { [weak self] state in
            self?.update { $0.deviceState = state }
        }
    }

    func addObserver(_ observer: @escaping (Snapshot) -> Void) -> UUID {
        precondition(Thread.isMainThread)
        let token = UUID()
        observers[token] = observer
        observer(snapshot)
        return token
    }

    func removeObserver(_ token: UUID) {
        precondition(Thread.isMainThread)
        observers.removeValue(forKey: token)
    }

    func start() {
        precondition(Thread.isMainThread)
        guard !started, !isShutdown else { return }
        started = true
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applicationDidWake()
        }
        usbController.start()
    }

    func setAudioComponentReady(_ ready: Bool) {
        usbController.setAudioComponentReady(ready)
    }

    func selectDevice(_ udid: String) {
        usbController.selectDevice(udid)
        publish()
    }

    func resumeConnectionByUser() {
        precondition(Thread.isMainThread)
        guard !isShutdown else { return }
        userStopped = false
        usbController.resumeByUser()
        publish()
    }

    func stopConnectionByUser() {
        precondition(Thread.isMainThread)
        guard !isShutdown else { return }
        userStopped = true
        usbController.stopByUser()
        publish()
    }

    func toggleConnectionByUser() {
        if userStopped { resumeConnectionByUser() }
        else { stopConnectionByUser() }
    }

    func toggleMuteByUser() {
        guard !isShutdown else { return }
        receiver.toggleMuted()
    }

    func connectWiFi(host: String, pairingCode: String) {
        precondition(Thread.isMainThread)
        guard !isShutdown else { return }
        userStopped = true
        usbController.pauseForWiFi { [weak self] in
            guard let self = self, !self.isShutdown else { return }
            self.receiver.connect(host: host, pairingCode: pairingCode)
            self.publish()
        }
        publish()
    }

    func applicationDidWake() {
        guard !isShutdown else { return }
        usbController.applicationDidWake()
    }

    func shutdown() {
        precondition(Thread.isMainThread)
        guard !isShutdown else { return }
        isShutdown = true
        if let wakeObserver = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        usbController.shutdown()
        receiver.shutdown()
        observers.removeAll()
    }

    private var snapshot: Snapshot {
        Snapshot(
            status: status,
            deviceState: deviceState,
            isMuted: isMuted,
            userStopped: userStopped,
            metrics: metrics
        )
    }

    private func update(_ mutation: @escaping (CamMicSessionCoordinator) -> Void) {
        let apply = { [weak self] in
            guard let self = self, !self.isShutdown else { return }
            mutation(self)
            self.publish()
        }
        if Thread.isMainThread { apply() }
        else { eventDelivery(apply) }
    }

    private func publish() {
        precondition(Thread.isMainThread)
        let state = snapshot
        for observer in observers.values { observer(state) }
    }
}
