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
        // Keep the runtime Dock icon on the same alpha-preserving macOS ICNS as the bundle resource.
        if let iconURL = Bundle.main.url(forResource: "CamMic", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }

        let content = MacMainViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 510),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CamMic"
        content.preferredContentSize = NSSize(width: 560, height: 510)
        window.contentViewController = content
        window.setContentSize(NSSize(width: 560, height: 510))
        window.minSize = NSSize(width: 520, height: 480)
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
        appMenu.addItem(NSMenuItem(
            title: "Quit CamMic",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        appMenuItem.title = "CamMic"
        appMenuItem.submenu = appMenu
        NSApp.mainMenu = menu
    }
}

final class MacMainViewController: NSViewController {
    private let receiver = MacAudioReceiver()

    private let addressField = NSTextField()
    private let pairingCodeField = NSSecureTextField()
    private let audioComponentLabel = NSTextField(labelWithString: "正在检查 CamMic 音频组件…")
    private let statusLabel = NSTextField(labelWithString: "")
    private let metricsLabel = NSTextField(labelWithString: "播放缓冲：—")
    private let connectButton = NSButton(title: "连接 iPhone", target: nil, action: nil)
    private let disconnectButton = NSButton(title: "停止并静音", target: nil, action: nil)
    private let refreshAudioButton = NSButton(title: "检查组件", target: nil, action: nil)
    private let installAudioButton = NSButton(title: "安装或修复音频组件", target: nil, action: nil)
    private let inputSettingsButton = NSButton(title: "打开麦克风输入设置", target: nil, action: nil)
    private var componentReady = false

    override func loadView() {
        view = NSView()
        buildInterface()
        bindReceiver()
        refreshAudioComponent()
    }

    private func buildInterface() {
        let title = NSTextField(labelWithString: "CamMic")
        title.font = .boldSystemFont(ofSize: 24)

        let subtitle = NSTextField(wrappingLabelWithString: "将 iPhone 麦克风送入 Mac 的 CamMic 系统输入设备。CamMic App 使用专用隐藏输出端写入；Mac 默认扬声器保持不变。")
        subtitle.maximumNumberOfLines = 3

        audioComponentLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        audioComponentLabel.maximumNumberOfLines = 2
        statusLabel.maximumNumberOfLines = 3
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        metricsLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        metricsLabel.maximumNumberOfLines = 3

        let addressLabel = NSTextField(labelWithString: "iPhone IP 或 USB 地址")
        addressField.placeholderString = "Wi-Fi：iPhone 局域网 IP    USB：127.0.0.1"
        addressField.stringValue = ""

        let codeLabel = NSTextField(labelWithString: "iPhone 配对码")
        pairingCodeField.placeholderString = "8 位数字，每次采音重新生成"

        refreshAudioButton.target = self
        refreshAudioButton.action = #selector(refreshAudioButtonTapped)
        installAudioButton.target = self
        installAudioButton.action = #selector(installAudioButtonTapped)
        inputSettingsButton.target = self
        inputSettingsButton.action = #selector(inputSettingsButtonTapped)
        connectButton.target = self
        connectButton.action = #selector(connectTapped)
        disconnectButton.target = self
        disconnectButton.action = #selector(disconnectTapped)
        disconnectButton.keyEquivalent = String(UnicodeScalar(27)!)

        let componentButtons = NSStackView(views: [refreshAudioButton, installAudioButton, inputSettingsButton])
        componentButtons.orientation = .horizontal
        componentButtons.spacing = 10

        let connectionButtons = NSStackView(views: [connectButton, disconnectButton])
        connectionButtons.orientation = .horizontal
        connectionButtons.spacing = 12

        let stack = NSStackView(views: [
            title, subtitle, audioComponentLabel, componentButtons,
            addressLabel, addressField, codeLabel, pairingCodeField,
            connectionButtons, statusLabel, metricsLabel
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 13
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            addressField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pairingCodeField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            audioComponentLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            metricsLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func bindReceiver() {
        receiver.onStatus = { [weak self] message in self?.statusLabel.stringValue = message }
        receiver.onMetrics = { [weak self] metrics in
            guard let self = self else { return }
            let milliseconds = Double(metrics.queuedFrames) * 1000 / metrics.outputSampleRate
            self.metricsLabel.stringValue = String(
                format: "接收：%llu 包 / %llu bytes · PCM RMS %.4f / peak %.4f\n播放缓冲：%d 帧 / %d 包 / %.0f ms（非端到端延迟）· 协议错误：%llu · 欠载：%llu · 回调竞争：%llu · 已消费：%llu",
                metrics.receivedPackets,
                metrics.receivedPCMBytes,
                metrics.receivedPCMRMS,
                metrics.receivedPCMPeak,
                metrics.queuedFrames,
                metrics.queuedPackets,
                milliseconds,
                metrics.protocolErrors,
                metrics.underrunCallbacks,
                metrics.renderContentions,
                metrics.lastConsumedSequence
            )
        }
    }

    func shutdown() {
        receiver.shutdown()
    }

    @objc private func refreshAudioButtonTapped() { refreshAudioComponent() }

    private func refreshAudioComponent() {
        guard let endpoints = CamMicAudioDevices.current() else {
            componentReady = false
            connectButton.isEnabled = false
            audioComponentLabel.stringValue = "CamMic 音频组件：未安装或未就绪。系统输入列表中暂不可用。"
            let instruction = "安装或修复 CamMic 驱动后，点“检查组件”；就绪后在 QuickTime 等应用中选择 CamMic 麦克风。"
            statusLabel.stringValue = instruction
            receiver.disconnect(statusMessage: instruction)
            return
        }

        componentReady = true
        connectButton.isEnabled = true
        audioComponentLabel.stringValue = "系统麦克风：\(endpoints.microphone.name) · CamMic 内部输出：已就绪"
        statusLabel.stringValue = "填写 iPhone 的局域网 IP 或 USB 地址及当前配对码，然后连接。"
    }

    @objc private func installAudioButtonTapped() {
        let embeddedPackage = Bundle.main.url(forResource: "CamMicAudioDriver", withExtension: "pkg")
        let installationPage = URL(string: "https://github.com/YYKX682436/CamMic#install-on-macos")!
        let destination = embeddedPackage ?? installationPage
        if NSWorkspace.shared.open(destination) {
            statusLabel.stringValue = embeddedPackage == nil
                ? "已打开 CamMic 安装说明。安装驱动时会短暂重启 macOS 音频服务。"
                : "已打开 CamMic 驱动安装器。关闭正在录音的应用，安装会短暂重启 macOS 音频服务。"
        } else {
            statusLabel.stringValue = "无法打开安装器。请从 CamMic 仓库的 macOS 安装说明下载并运行安装包。"
        }
    }

    @objc private func inputSettingsButtonTapped() {
        let soundSettings = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!
        if NSWorkspace.shared.open(soundSettings) {
            statusLabel.stringValue = "已打开声音输入设置。选择 CamMic 作为麦克风输入；这不会更改扬声器输出。"
        } else {
            statusLabel.stringValue = "无法打开声音设置。请在系统设置 → 声音 → 输入中选择 CamMic。"
        }
    }

    @objc private func connectTapped() {
        guard componentReady else {
            refreshAudioComponent()
            return
        }
        metricsLabel.stringValue = "正在建立新会话；旧会话计数已清除。"
        receiver.connect(host: addressField.stringValue, pairingCode: pairingCodeField.stringValue)
    }

    @objc private func disconnectTapped() {
        receiver.disconnect()
        metricsLabel.stringValue = "播放缓冲：已清空 · 输出静音"
    }
}
