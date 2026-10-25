import AppKit
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
        let content = MacMainViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CamMic Mac Receiver"
        window.contentViewController = content
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

final class MacMainViewController: NSViewController {
    private let receiver = MacAudioReceiver()
    private var devices: [AudioOutputDevice] = []

    private let addressField = NSTextField()
    private let pairingCodeField = NSSecureTextField()
    private let devicePopup = NSPopUpButton()
    private let statusLabel = NSTextField(labelWithString: "请选择输出设备，再填写 iPhone 地址和配对码。")
    private let metricsLabel = NSTextField(labelWithString: "播放缓冲：—")
    private let connectButton = NSButton(title: "连接 iPhone", target: nil, action: nil)
    private let disconnectButton = NSButton(title: "停止并静音", target: nil, action: nil)

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        buildInterface()
        bindReceiver()
        refreshDevices()
    }

    private func buildInterface() {
        let title = NSTextField(labelWithString: "CamMic · 系统麦克风接收端")
        title.font = .boldSystemFont(ofSize: 22)

        let subtitle = NSTextField(wrappingLabelWithString: "Mac 主动连接 iPhone。BlackHole 2ch 接收单声道人声，QuickTime 等应用可将 BlackHole 选作麦克风。系统扬声器监听默认关闭。")
        subtitle.maximumNumberOfLines = 3

        let addressLabel = NSTextField(labelWithString: "iPhone IP 或 USB 地址")
        addressField.placeholderString = "Wi-Fi：iPhone 局域网 IP    USB：127.0.0.1"
        addressField.stringValue = ""

        let codeLabel = NSTextField(labelWithString: "iPhone 配对码")
        pairingCodeField.placeholderString = "8 位数字，每次采音重新生成"

        let deviceLabel = NSTextField(labelWithString: "输出设备（通过 UID 选择）")
        devicePopup.target = self
        devicePopup.action = #selector(outputDeviceChanged)
        devicePopup.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let refreshButton = NSButton(title: "刷新设备", target: self, action: #selector(refreshDeviceButton))
        connectButton.target = self
        connectButton.action = #selector(connectTapped)
        disconnectButton.target = self
        disconnectButton.action = #selector(disconnectTapped)

        statusLabel.maximumNumberOfLines = 3
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        metricsLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        disconnectButton.keyEquivalent = String(UnicodeScalar(27)!)

        let deviceRow = NSStackView(views: [devicePopup, refreshButton])
        deviceRow.orientation = .horizontal
        deviceRow.spacing = 10

        let buttonRow = NSStackView(views: [connectButton, disconnectButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 12

        let stack = NSStackView(views: [
            title, subtitle, addressLabel, addressField, codeLabel, pairingCodeField,
            deviceLabel, deviceRow, buttonRow, statusLabel, metricsLabel
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            addressField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pairingCodeField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            devicePopup.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.76),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            metricsLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func bindReceiver() {
        receiver.onStatus = { [weak self] message in self?.statusLabel.stringValue = message }
        receiver.onMetrics = { [weak self] metrics in
            guard let self = self else { return }
            let rate = self.selectedDevice()?.sampleRate ?? 48_000
            let milliseconds = Double(metrics.queuedFrames) * 1000 / rate
            self.metricsLabel.stringValue = String(
                format: "播放缓冲：%d 帧 / %d 包 / %.0f ms（非端到端延迟）· 接收：%llu 包 · 异常：%llu · 欠载回调：%llu · 已消费：%llu",
                metrics.queuedFrames,
                metrics.queuedPackets,
                milliseconds,
                metrics.receivedPackets,
                metrics.protocolErrors,
                metrics.underrunCallbacks,
                metrics.lastConsumedSequence
            )
        }
    }

    @objc private func refreshDeviceButton() { refreshDevices() }

    private func refreshDevices() {
        receiver.disconnect()
        do {
            devices = try AudioDeviceCatalog.outputs()
            devicePopup.removeAllItems()
            devicePopup.addItem(withTitle: "选择输出设备（BlackHole 2ch 推荐）")
            devicePopup.item(at: 0)?.representedObject = nil
            for device in devices {
                devicePopup.addItem(withTitle: device.displayName)
                devicePopup.lastItem?.representedObject = device.uid
            }
            if let blackHoleIndex = devices.firstIndex(where: { $0.name.localizedCaseInsensitiveContains("BlackHole 2ch") }) {
                devicePopup.selectItem(at: blackHoleIndex + 1)
                statusLabel.stringValue = "已找到 BlackHole 2ch。安装该独立驱动后，在 QuickTime 中选择 BlackHole 2ch 麦克风输入。"
            } else {
                devicePopup.selectItem(at: 0)
                statusLabel.stringValue = "未找到 BlackHole 2ch。请单独安装 BlackHole 2ch，再刷新设备；没有选定设备时不会连接或回退到扬声器。"
            }
        } catch {
            devices = []
            devicePopup.removeAllItems()
            devicePopup.addItem(withTitle: "没有可用的双声道输出设备")
            statusLabel.stringValue = error.localizedDescription
        }
    }

    private func selectedDevice() -> AudioOutputDevice? {
        guard let uid = devicePopup.selectedItem?.representedObject as? String else { return nil }
        return devices.first(where: { $0.uid == uid })
    }

    @objc private func outputDeviceChanged() {
        receiver.disconnect()
        metricsLabel.stringValue = "输出设备已切换；旧会话已静音并清空，请重新连接。"
    }

    @objc private func connectTapped() {
        guard let device = selectedDevice() else {
            statusLabel.stringValue = "请先明确选择输出设备；推荐 BlackHole 2ch。"
            return
        }
        metricsLabel.stringValue = "正在建立新会话；旧会话计数已清除。"
        receiver.connect(
            host: addressField.stringValue,
            pairingCode: pairingCodeField.stringValue,
            device: device
        )
    }

    @objc private func disconnectTapped() {
        receiver.disconnect()
        metricsLabel.stringValue = "播放缓冲：已清空 · 输出静音"
    }
}
