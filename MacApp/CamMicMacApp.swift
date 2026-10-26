import AppKit
import CamMicMacCore
import Foundation

@main
enum CamMicMacMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installApplicationMenu()
        if let iconURL = Bundle.main.url(forResource: "CamMic", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }

        let content = MacMainViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CamMic"
        content.preferredContentSize = NSSize(width: 560, height: 460)
        window.contentViewController = content
        window.setContentSize(NSSize(width: 560, height: 460))
        window.minSize = NSSize(width: 520, height: 420)
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        (window?.contentViewController as? MacMainViewController)?.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func installApplicationMenu() {
        let menu = NSMenu()
        let appMenuItem = NSMenuItem()
        menu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "CamMic")
        appMenu.addItem(NSMenuItem(
            title: "About CamMic",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        ))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit CamMic", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.title = "CamMic"
        appMenuItem.submenu = appMenu
        NSApp.mainMenu = menu
    }
}

final class MacMainViewController: NSViewController {
    private let receiver: MacAudioReceiver
    private let usbController: USBAutoConnectionController

    private let audioComponentLabel = NSTextField(labelWithString: "正在检查 CamMic 麦克风…")
    private let selectedDeviceLabel = NSTextField(labelWithString: "等待 iPhone")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let levelLabel = NSTextField(labelWithString: "iPhone 麦克风电平：—")
    private let metricsLabel = NSTextField(wrappingLabelWithString: "")
    private let levelMeter = NSLevelIndicator()
    private let devicePopup = NSPopUpButton()
    private let addressField = NSTextField()
    private let pairingCodeField = NSSecureTextField()
    private let connectUSBButton = NSButton(title: "连接 iPhone", target: nil, action: nil)
    private let muteButton = NSButton(title: "静音", target: nil, action: nil)
    private let stopButton = NSButton(title: "停止并静音", target: nil, action: nil)
    private let advancedButton = NSButton(title: "高级选项 ▸", target: nil, action: nil)
    private let wifiButton = NSButton(title: "连接 Wi-Fi iPhone", target: nil, action: nil)
    private let refreshAudioButton = NSButton(title: "检查音频组件", target: nil, action: nil)
    private let installAudioButton = NSButton(title: "安装或修复 CamMic 麦克风", target: nil, action: nil)
    private let inputSettingsButton = NSButton(title: "打开麦克风输入设置", target: nil, action: nil)
    private let advancedStack = NSStackView()

    private var componentReady = false
    private var advancedVisible = false
    private var muted = false
    private var availableDevices: [CamMicUSBDevice] = []
    private var selectedDeviceID: String?

    init() {
        let receiver = MacAudioReceiver()
        self.receiver = receiver
        self.usbController = USBAutoConnectionController(receiver: receiver)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        let receiver = MacAudioReceiver()
        self.receiver = receiver
        self.usbController = USBAutoConnectionController(receiver: receiver)
        super.init(coder: coder)
    }

    override func loadView() {
        view = NSView()
        buildInterface()
        bindReceiver()
        refreshAudioComponent()
        usbController.start()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    private func buildInterface() {
        let title = NSTextField(labelWithString: "CamMic")
        title.font = .boldSystemFont(ofSize: 24)
        let subtitle = NSTextField(wrappingLabelWithString: "在 iPhone 上启动采音并插入 USB，CamMic 会自动连接。然后在 Mac 的录音应用中选择 CamMic 麦克风。")
        subtitle.maximumNumberOfLines = 3
        subtitle.lineBreakMode = .byWordWrapping

        audioComponentLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.maximumNumberOfLines = 3
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        selectedDeviceLabel.font = .systemFont(ofSize: 14, weight: .medium)
        metricsLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        metricsLabel.maximumNumberOfLines = 4

        levelMeter.minValue = 0
        levelMeter.maxValue = 1
        levelMeter.warningValue = 0.65
        levelMeter.criticalValue = 0.9
        levelMeter.levelIndicatorStyle = .continuousCapacity
        levelMeter.isEditable = false

        devicePopup.target = self
        devicePopup.action = #selector(deviceSelectionChanged)
        connectUSBButton.target = self
        connectUSBButton.action = #selector(connectUSBTapped)
        muteButton.target = self
        muteButton.action = #selector(muteTapped)
        stopButton.target = self
        stopButton.action = #selector(stopTapped)
        advancedButton.target = self
        advancedButton.action = #selector(advancedTapped)
        wifiButton.target = self
        wifiButton.action = #selector(wifiTapped)
        refreshAudioButton.target = self
        refreshAudioButton.action = #selector(refreshAudioButtonTapped)
        installAudioButton.target = self
        installAudioButton.action = #selector(installAudioButtonTapped)
        inputSettingsButton.target = self
        inputSettingsButton.action = #selector(inputSettingsButtonTapped)
        stopButton.keyEquivalent = String(UnicodeScalar(27)!)

        addressField.placeholderString = "iPhone 局域网 IP 地址"
        pairingCodeField.placeholderString = "iPhone 上显示的 8 位配对码"
        let addressLabel = NSTextField(labelWithString: "Wi-Fi 地址")
        let pairingLabel = NSTextField(labelWithString: "Wi-Fi 配对码")
        let addressRow = NSStackView(views: [addressLabel, addressField])
        let codeRow = NSStackView(views: [pairingLabel, pairingCodeField])
        addressRow.orientation = .horizontal
        codeRow.orientation = .horizontal
        addressRow.alignment = .centerY
        codeRow.alignment = .centerY
        addressRow.spacing = 12
        codeRow.spacing = 12

        let componentButtons = NSStackView(views: [refreshAudioButton, inputSettingsButton])
        componentButtons.orientation = .horizontal
        componentButtons.spacing = 10
        let connectionButtons = NSStackView(views: [connectUSBButton, muteButton, stopButton])
        connectionButtons.orientation = .horizontal
        connectionButtons.spacing = 12

        advancedStack.orientation = .vertical
        advancedStack.alignment = .leading
        advancedStack.spacing = 9
        advancedStack.addArrangedSubview(addressRow)
        advancedStack.addArrangedSubview(codeRow)
        advancedStack.addArrangedSubview(wifiButton)
        advancedStack.addArrangedSubview(metricsLabel)
        advancedStack.addArrangedSubview(componentButtons)
        advancedStack.isHidden = true

        let stack = NSStackView(views: [
            title, subtitle, audioComponentLabel, selectedDeviceLabel, devicePopup,
            levelLabel, levelMeter, connectionButtons, statusLabel, installAudioButton,
            advancedButton, advancedStack
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 22),
            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            audioComponentLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            levelMeter.widthAnchor.constraint(equalTo: stack.widthAnchor),
            devicePopup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            metricsLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            addressField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            pairingCodeField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240)
        ])
    }

    private func bindReceiver() {
        receiver.onStatus = { [weak self] message in self?.statusLabel.stringValue = message }
        receiver.onMetrics = { [weak self] metrics in
            guard let self = self else { return }
            self.levelLabel.stringValue = String(format: "iPhone 麦克风电平：RMS %.3f · peak %.3f", metrics.receivedPCMRMS, metrics.receivedPCMPeak)
            self.levelMeter.doubleValue = min(1, metrics.receivedPCMRMS * 10)
            let milliseconds = Double(metrics.queuedFrames) * 1000 / metrics.outputSampleRate
            self.metricsLabel.stringValue = String(
                format: "接收：%llu 包 / %llu bytes · 缓冲：%d 帧 / %.0f ms · 协议错误：%llu · 欠载：%llu · 已消费：%llu",
                metrics.receivedPackets,
                metrics.receivedPCMBytes,
                metrics.queuedFrames,
                milliseconds,
                metrics.protocolErrors,
                metrics.underrunCallbacks,
                metrics.lastConsumedSequence
            )
        }
        usbController.onStatus = { [weak self] message in self?.statusLabel.stringValue = message }
        usbController.onDeviceState = { [weak self] state in self?.updateDevices(state) }
    }

    func shutdown() {
        usbController.shutdown()
        receiver.shutdown()
    }

    private func refreshAudioComponent() {
        guard let endpoints = CamMicAudioDevices.current() else {
            componentReady = false
            connectUSBButton.isEnabled = false
            installAudioButton.isHidden = false
            audioComponentLabel.stringValue = "CamMic 麦克风尚未安装。"
            statusLabel.stringValue = "安装 CamMic 麦克风后，即可通过 USB 自动连接 iPhone。"
            usbController.setAudioComponentReady(false)
            return
        }
        componentReady = true
        connectUSBButton.isEnabled = true
        installAudioButton.isHidden = true
        audioComponentLabel.stringValue = "CamMic 麦克风已就绪：\(endpoints.microphone.name)"
        usbController.setAudioComponentReady(true)
    }

    private func updateDevices(_ state: USBAutoConnectionController.DeviceState) {
        availableDevices = state.devices
        selectedDeviceID = state.selectedDeviceID
        devicePopup.removeAllItems()
        for device in state.devices {
            devicePopup.addItem(withTitle: device.displayName)
            devicePopup.lastItem?.representedObject = device.udid
        }
        if let selected = state.selectedDeviceID,
           let index = devicePopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == selected }) {
            devicePopup.selectItem(at: index)
            selectedDeviceLabel.stringValue = state.devices.first(where: { $0.udid == selected })?.displayName ?? "已选择 iPhone"
        } else if state.devices.count > 1 {
            selectedDeviceLabel.stringValue = "检测到多台 iPhone，请选择设备"
        } else if state.devices.isEmpty {
            selectedDeviceLabel.stringValue = "等待 iPhone"
        }
        devicePopup.isHidden = state.devices.count < 2
        connectUSBButton.isEnabled = componentReady && state.selectedDeviceID != nil
    }

    @objc private func deviceSelectionChanged() {
        guard let udid = devicePopup.selectedItem?.representedObject as? String else { return }
        usbController.selectDevice(udid)
    }

    @objc private func connectUSBTapped() { usbController.resumeByUser() }

    @objc private func muteTapped() {
        muted.toggle()
        receiver.setMuted(muted)
        muteButton.title = muted ? "取消静音" : "静音"
    }

    @objc private func stopTapped() {
        usbController.stopByUser()
        receiver.setMuted(true)
        muted = true
        muteButton.title = "取消静音"
        levelMeter.doubleValue = 0
        levelLabel.stringValue = "iPhone 麦克风电平：已静音"
    }

    @objc private func advancedTapped() {
        advancedVisible.toggle()
        advancedStack.isHidden = !advancedVisible
        advancedButton.title = advancedVisible ? "高级选项 ▾" : "高级选项 ▸"
    }

    @objc private func refreshAudioButtonTapped() { refreshAudioComponent() }

    @objc private func installAudioButtonTapped() {
        let embeddedPackage = Bundle.main.url(forResource: "CamMicAudioDriver", withExtension: "pkg")
        let installationPage = URL(string: "https://github.com/YYKX682436/CamMic#install-on-macos")!
        let destination = embeddedPackage ?? installationPage
        _ = NSWorkspace.shared.open(destination)
    }

    @objc private func inputSettingsButtonTapped() {
        let soundSettings = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!
        _ = NSWorkspace.shared.open(soundSettings)
    }

    @objc private func wifiTapped() {
        guard componentReady else { refreshAudioComponent(); return }
        usbController.pauseForWiFi { [weak self] in
            guard let self = self else { return }
            self.receiver.setMuted(self.muted)
            self.receiver.connect(host: self.addressField.stringValue, pairingCode: self.pairingCodeField.stringValue)
        }
    }

    @objc private func applicationDidWake(_ notification: Notification) { usbController.applicationDidWake() }
}
