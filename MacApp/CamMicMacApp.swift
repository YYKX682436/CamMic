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
    private var session: CamMicSessionCoordinator!
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private let connectionStatusItem = NSMenuItem(title: "状态：等待 iPhone", action: nil, keyEquivalent: "")
    private let muteMenuItem = NSMenuItem(title: "静音", action: nil, keyEquivalent: "")
    private let connectionMenuItem = NSMenuItem(title: "停止连接", action: nil, keyEquivalent: "")

    init(session: CamMicSessionCoordinator? = nil) {
        self.session = session
        super.init()
    }

    var windowForTesting: NSWindow? { window }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installApplicationMenu()
        if let iconURL = Bundle.main.url(forResource: "CamMic", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }

        session = CamMicSessionCoordinator()
        session.start()
        installStatusItem()
        openMainWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        session.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openMainWindow()
        return true
    }

    private func openMainWindow() {
        if window == nil {
            let content = MacMainViewController(session: session)
            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            newWindow.title = "CamMic"
            newWindow.isReleasedWhenClosed = false
            content.preferredContentSize = NSSize(width: 560, height: 460)
            newWindow.contentViewController = content
            newWindow.setContentSize(NSSize(width: 560, height: 460))
            newWindow.minSize = NSSize(width: 520, height: 420)
            newWindow.center()
            window = newWindow
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "CamMic"
        item.button?.toolTip = "CamMic 菜单栏控制"

        let menu = NSMenu(title: "CamMic")
        connectionStatusItem.isEnabled = false
        menu.addItem(connectionStatusItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "打开 CamMic", action: #selector(openMainWindowFromMenu), keyEquivalent: ""))
        muteMenuItem.action = #selector(toggleMuteFromMenu)
        muteMenuItem.target = self
        menu.addItem(muteMenuItem)
        connectionMenuItem.target = self
        connectionMenuItem.action = #selector(toggleConnectionFromMenu)
        menu.addItem(connectionMenuItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 CamMic", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        item.menu = menu
        statusItem = item

        _ = session.addObserver { [weak self] snapshot in
            guard let self = self else { return }
            let compactStatus = String(snapshot.status.prefix(72))
            self.connectionStatusItem.title = "状态：\(compactStatus)"
            if snapshot.status.count > 72 { self.connectionStatusItem.title += "…" }
            self.muteMenuItem.title = snapshot.isMuted ? "取消静音" : "静音"
            self.connectionMenuItem.title = snapshot.userStopped ? "恢复连接" : "停止连接"
        }
    }

    @objc private func openMainWindowFromMenu() { openMainWindow() }

    @objc func toggleMuteFromMenu() { session.toggleMuteByUser() }

    @objc func toggleConnectionFromMenu() { session.toggleConnectionByUser() }

    private func installApplicationMenu() {
        let menu = NSMenu()
        let appMenuItem = NSMenuItem()
        menu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "CamMic")
        let about = NSMenuItem(
            title: "About CamMic",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        about.target = NSApp
        appMenu.addItem(about)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit CamMic", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        appMenu.addItem(quit)
        appMenuItem.title = "CamMic"
        appMenuItem.submenu = appMenu
        NSApp.mainMenu = menu
    }
}

final class MacMainViewController: NSViewController {
    private let session: CamMicSessionCoordinator
    private var sessionObserver: UUID?

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
    private let stopButton = NSButton(title: "停止连接", target: nil, action: nil)
    private let advancedButton = NSButton(title: "高级选项 ▸", target: nil, action: nil)
    private let wifiButton = NSButton(title: "连接 Wi-Fi iPhone", target: nil, action: nil)
    private let refreshAudioButton = NSButton(title: "检查音频组件", target: nil, action: nil)
    private let installAudioButton = NSButton(title: "安装或修复 CamMic 麦克风", target: nil, action: nil)
    private let inputSettingsButton = NSButton(title: "打开麦克风输入设置", target: nil, action: nil)
    private let advancedStack = NSStackView()

    private var componentReady = false
    private var advancedVisible = false

    var sessionForTesting: CamMicSessionCoordinator { session }

    init(session: CamMicSessionCoordinator) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func loadView() {
        view = NSView()
        buildInterface()
        bindSession()
        refreshAudioComponent()
    }

    deinit {
        guard let sessionObserver = sessionObserver else { return }
        if Thread.isMainThread {
            session.removeObserver(sessionObserver)
        } else {
            let activeSession = session
            DispatchQueue.main.async { [weak activeSession] in activeSession?.removeObserver(sessionObserver) }
        }
    }

    private func bindSession() {
        sessionObserver = session.addObserver { [weak self] snapshot in
            self?.consumeSessionSnapshot(snapshot)
        }
    }

    private func consumeSessionSnapshot(_ snapshot: CamMicSessionCoordinator.Snapshot) {
        precondition(Thread.isMainThread)
        statusLabel.stringValue = snapshot.status
        muteButton.title = snapshot.isMuted ? "取消静音" : "静音"
        stopButton.title = snapshot.userStopped ? "恢复连接" : "停止连接"
        updateDevices(snapshot.deviceState)
        if let metrics = snapshot.metrics { updateMetrics(metrics) }
    }

    private func updateMetrics(_ metrics: MacAudioReceiver.Metrics) {
        levelLabel.stringValue = String(format: "iPhone 麦克风电平：RMS %.3f · peak %.3f", metrics.receivedPCMRMS, metrics.receivedPCMPeak)
        levelMeter.doubleValue = min(1, metrics.receivedPCMRMS * 10)
        let milliseconds = Double(metrics.queuedFrames) * 1000 / metrics.outputSampleRate
        metricsLabel.stringValue = String(
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

    private func refreshAudioComponent() {
        guard let endpoints = CamMicAudioDevices.current() else {
            componentReady = false
            connectUSBButton.isEnabled = false
            installAudioButton.isHidden = false
            audioComponentLabel.stringValue = "CamMic 麦克风尚未安装。"
            statusLabel.stringValue = "安装 CamMic 麦克风后，即可通过 USB 自动连接 iPhone。"
            session.setAudioComponentReady(false)
            return
        }
        componentReady = true
        connectUSBButton.isEnabled = true
        installAudioButton.isHidden = true
        audioComponentLabel.stringValue = "CamMic 麦克风已就绪：\(endpoints.microphone.name)"
        session.setAudioComponentReady(true)
    }

    private func updateDevices(_ state: USBAutoConnectionController.DeviceState) {
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
        session.selectDevice(udid)
    }

    @objc func connectUSBTapped() { session.resumeConnectionByUser() }

    @objc func muteTapped() { session.toggleMuteByUser() }

    @objc func stopTapped() {
        session.toggleConnectionByUser()
        levelMeter.doubleValue = 0
        levelLabel.stringValue = "iPhone 麦克风电平：已停止"
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
        session.connectWiFi(host: addressField.stringValue, pairingCode: pairingCodeField.stringValue)
    }
}
