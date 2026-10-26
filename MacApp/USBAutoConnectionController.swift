import Foundation

protocol CamMicUSBReceiving: AnyObject {
    var onUSBAttemptEnded: ((UUID, String) -> Void)? { get set }
    var onUSBHandshakeReady: ((UUID) -> Void)? { get set }
    func connectUSB(initializationPort: UInt16, audioPort: UInt16) -> UUID
    func disconnect(statusMessage: String)
}

final class USBAutoConnectionController {
    struct DeviceState: Equatable {
        let devices: [CamMicUSBDevice]
        let selectedDeviceID: String?
    }

    var onStatus: ((String) -> Void)?
    var onDeviceState: ((DeviceState) -> Void)?

    private let discovery: CamMicUSBDeviceDiscovering
    private let forwarders: CamMicUSBForwarderCreating
    private let receiver: CamMicUSBReceiving
    private let queue = DispatchQueue(label: "com.yykx682436.CamMic.usb-manager", qos: .userInitiated)
    private let eventDelivery: (@escaping () -> Void) -> Void
    private let preferredDevice: () -> String?
    private let rememberDevice: (String) -> Void
    private let retryDelays: [TimeInterval]

    private var devices: [String: CamMicUSBDevice] = [:]
    private var selectedDeviceID: String?
    private var initialized = false
    private var isShutdown = false
    private var componentReady = false
    private var userStopped = false
    private var attemptToken: UUID?
    private var initializationForwarder: CamMicUSBForwarding?
    private var audioForwarder: CamMicUSBForwarding?
    private var retryWorkItem: DispatchWorkItem?
    private var discoveryRetryWorkItem: DispatchWorkItem?
    private var retryIndex = 0
    private var discoveryRetryIndex = 0

    init(
        discovery: CamMicUSBDeviceDiscovering = LibUSBMuxDeviceDiscovery(),
        forwarders: CamMicUSBForwarderCreating = LibUSBMuxForwarderFactory(),
        receiver: CamMicUSBReceiving,
        eventDelivery: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
        preferredDevice: @escaping () -> String? = { UserDefaults.standard.string(forKey: "CamMic.preferredUSBDevice") },
        rememberDevice: @escaping (String) -> Void = { UserDefaults.standard.set($0, forKey: "CamMic.preferredUSBDevice") },
        retryDelays: [TimeInterval] = [1, 2, 4, 8]
    ) {
        self.discovery = discovery
        self.forwarders = forwarders
        self.receiver = receiver
        self.eventDelivery = eventDelivery
        self.preferredDevice = preferredDevice
        self.rememberDevice = rememberDevice
        self.retryDelays = retryDelays.isEmpty ? [8] : retryDelays
        receiver.onUSBAttemptEnded = { [weak self] token, message in
            self?.queue.async { self?.attemptEnded(token: token, message: message) }
        }
        receiver.onUSBHandshakeReady = { [weak self] token in
            self?.queue.async { self?.handshakeReady(token: token) }
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self = self, !self.initialized, !self.isShutdown else { return }
            self.initialized = true
            self.discovery.onDeviceEvent = { [weak self] event, device in
                self?.queue.async { self?.consumeDeviceEvent(event, device: device) }
            }
            self.startDiscovery()
        }
    }

    func setAudioComponentReady(_ ready: Bool) {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard !self.isShutdown else { return }
            self.componentReady = ready
            if ready { self.connectIfAllowed() }
            else { self.stopCurrent(status: "请先安装 CamMic 音频组件。") }
        }
    }

    func selectDevice(_ udid: String) {
        queue.async { [weak self] in
            guard let self = self, self.devices[udid] != nil else { return }
            guard !self.isShutdown else { return }
            self.userStopped = false
            self.retryIndex = 0
            self.retryWorkItem?.cancel()
            self.retryWorkItem = nil
            self.rememberDevice(udid)
            if self.selectedDeviceID != udid {
                self.stopCurrent(status: "正在切换 USB 设备…")
                self.selectedDeviceID = udid
            }
            self.publishDeviceState()
            self.connectIfAllowed()
        }
    }

    /// A user-requested stop takes precedence over USB insertion and retries.
    func stopByUser() {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard !self.isShutdown else { return }
            self.userStopped = true
            self.retryWorkItem?.cancel()
            self.retryWorkItem = nil
            self.retryIndex = 0
            self.stopCurrent(status: "已停止并静音。点“连接 iPhone”后才会恢复。")
        }
    }

    func resumeByUser() {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard !self.isShutdown else { return }
            self.userStopped = false
            self.retryIndex = 0
            self.retryWorkItem?.cancel()
            self.retryWorkItem = nil
            self.reconcileSelection()
            self.connectIfAllowed()
        }
    }

    /// Wi-Fi is an explicit advanced-mode choice and suppresses USB auto-reconnect.
    func pauseForWiFi(completion: @escaping () -> Void = {}) {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard !self.isShutdown else { return }
            self.userStopped = true
            self.retryWorkItem?.cancel()
            self.retryWorkItem = nil
            self.stopCurrent(status: "正在切换到高级 Wi-Fi 连接…")
            self.eventDelivery(completion)
        }
    }

    func deviceStateSnapshot(completion: @escaping (DeviceState) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let snapshot = self.makeDeviceState()
            self.eventDelivery { completion(snapshot) }
        }
    }

    func applicationDidWake() {
        queue.async { [weak self] in
            guard let self = self, !self.userStopped, !self.isShutdown else { return }
            self.retryIndex = 0
            self.stopCurrent(status: "Mac 已唤醒，正在恢复 USB 连接…")
            if self.discoveryRetryWorkItem != nil {
                self.discoveryRetryWorkItem?.cancel()
                self.discoveryRetryWorkItem = nil
                self.startDiscovery()
            } else {
                self.connectIfAllowed()
            }
        }
    }

    func shutdown() {
        queue.sync {
            guard !isShutdown else { return }
            isShutdown = true
            retryWorkItem?.cancel()
            retryWorkItem = nil
            discoveryRetryWorkItem?.cancel()
            discoveryRetryWorkItem = nil
            discovery.stop()
            stopForwarders()
            attemptToken = nil
            receiver.disconnect(statusMessage: "CamMic 已退出；输出已静音。")
            receiver.onUSBAttemptEnded = nil
            receiver.onUSBHandshakeReady = nil
        }
    }

    private func startDiscovery() {
        guard initialized, !isShutdown else { return }
        do {
            let current = try discovery.start()
            discoveryRetryWorkItem?.cancel()
            discoveryRetryWorkItem = nil
            discoveryRetryIndex = 0
            devices = Dictionary(current.map { ($0.udid, $0) }, uniquingKeysWith: { _, latest in latest })
            reconcileSelection()
        } catch {
            publishStatus(error.localizedDescription)
            publishDeviceState()
            scheduleDiscoveryRetry()
        }
    }

    private func scheduleDiscoveryRetry() {
        guard discoveryRetryWorkItem == nil, initialized, !isShutdown else { return }
        let delay = retryDelays[min(discoveryRetryIndex, retryDelays.count - 1)]
        discoveryRetryIndex = min(discoveryRetryIndex + 1, retryDelays.count - 1)
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.discoveryRetryWorkItem = nil
            self.startDiscovery()
        }
        discoveryRetryWorkItem = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func consumeDeviceEvent(_ event: Int32, device: CamMicUSBDevice) {
        guard !isShutdown else { return }
        // libusbmuxd reports UE_DEVICE_ADD = 1 and UE_DEVICE_REMOVE = 2.
        switch event {
        case 1:
            devices[device.udid] = device
        case 2:
            guard devices.removeValue(forKey: device.udid) != nil else { return }
            if selectedDeviceID == device.udid {
                stopCurrent(status: "iPhone 已断开 USB，CamMic 已静音。重新插入后会自动恢复。")
            }
        default:
            return
        }
        reconcileSelection()
    }

    private func reconcileSelection() {
        if let selectedDeviceID = selectedDeviceID, devices[selectedDeviceID] != nil {
            publishDeviceState()
            connectIfAllowed()
            return
        }
        let preferred = preferredDevice()
        let ordered = devices.keys.sorted()
        let next: String?
        if let preferred = preferred, devices[preferred] != nil {
            next = preferred
        } else if ordered.count == 1 {
            next = ordered.first
        } else {
            next = nil
        }
        if selectedDeviceID != next {
            stopForwarders()
            attemptToken = nil
            selectedDeviceID = next
        }
        publishDeviceState()
        if devices.count > 1, selectedDeviceID == nil {
            publishStatus("检测到多台 iPhone，请先选择要连接的设备。")
        } else if devices.isEmpty {
            publishStatus("等待 iPhone。请在手机上启动 CamMic 采音，再插入 USB。")
        } else if !componentReady {
            publishStatus("请先安装 CamMic 音频组件。")
        } else {
            connectIfAllowed()
        }
    }

    private func connectIfAllowed() {
        guard !isShutdown, !userStopped, componentReady, let selectedDeviceID = selectedDeviceID,
              let device = devices[selectedDeviceID], attemptToken == nil,
              retryWorkItem == nil else { return }
        do {
            if initializationForwarder == nil || audioForwarder == nil {
                stopForwarders()
                initializationForwarder = try forwarders.make(device: device, devicePort: 50889)
                audioForwarder = try forwarders.make(device: device, devicePort: 50890)
            }
            let initPort = initializationForwarder!.localPort
            let audioPort = audioForwarder!.localPort
            attemptToken = receiver.connectUSB(initializationPort: initPort, audioPort: audioPort)
            publishStatus("正在通过 USB 连接 \(device.displayName)…")
        } catch {
            stopForwarders()
            publishStatus(error.localizedDescription)
            scheduleRetry(deviceID: selectedDeviceID)
        }
    }

    private func attemptEnded(token: UUID, message: String) {
        guard !isShutdown else { return }
        guard attemptToken == token else { return }
        attemptToken = nil
        publishStatus(message)
        guard !userStopped, let selectedDeviceID = selectedDeviceID,
              devices[selectedDeviceID] != nil else { return }
        scheduleRetry(deviceID: selectedDeviceID)
    }

    private func handshakeReady(token: UUID) {
        guard !isShutdown else { return }
        guard attemptToken == token else { return }
        retryIndex = 0
        retryWorkItem?.cancel()
        retryWorkItem = nil
        if let selectedDeviceID = selectedDeviceID, let device = devices[selectedDeviceID] {
            publishStatus("已连接 \(device.displayName)。请在 Mac 应用中选择 CamMic 麦克风。")
        }
    }

    private func scheduleRetry(deviceID: String) {
        guard retryWorkItem == nil, !isShutdown, !userStopped, selectedDeviceID == deviceID,
              devices[deviceID] != nil else { return }
        let delay = retryDelays[min(retryIndex, retryDelays.count - 1)]
        retryIndex = min(retryIndex + 1, retryDelays.count - 1)
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.retryWorkItem = nil
            self.connectIfAllowed()
        }
        retryWorkItem = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func stopCurrent(status: String) {
        retryWorkItem?.cancel()
        retryWorkItem = nil
        attemptToken = nil
        stopForwarders()
        receiver.disconnect(statusMessage: status)
        publishStatus(status)
    }

    private func stopForwarders() {
        initializationForwarder?.stop()
        audioForwarder?.stop()
        initializationForwarder = nil
        audioForwarder = nil
    }

    private func makeDeviceState() -> DeviceState {
        DeviceState(devices: devices.values.sorted { $0.udid < $1.udid }, selectedDeviceID: selectedDeviceID)
    }

    private func publishDeviceState() {
        let snapshot = makeDeviceState()
        eventDelivery { [weak self] in self?.onDeviceState?(snapshot) }
    }

    private func publishStatus(_ message: String) {
        eventDelivery { [weak self] in self?.onStatus?(message) }
    }
}
