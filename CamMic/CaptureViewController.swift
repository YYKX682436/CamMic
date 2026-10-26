import AVFoundation
import UIKit

final class CaptureViewController: UIViewController {
    private let capture: AudioCaptureControlling
    private let link: AudioLinkServer

    private let permissionLabel = UILabel()
    private let statusLabel = UILabel()
    private let formatLabel = UILabel()
    private let pairingLabel = UILabel()
    private let levelLabel = UILabel()
    private let latencyLabel = UILabel()
    private let diagnosticsLabel = UILabel()
    private let meter = UIProgressView(progressViewStyle: .default)
    private let startButton = UIButton(type: .system)
    private let stopButton = UIButton(type: .system)
    private let settingsButton = UIButton(type: .system)
    private let advancedButton = UIButton(type: .system)
    private let wifiButton = UIButton(type: .system)
    private let advancedStack = UIStackView()
    private var advancedVisible = false
    private enum Transport: Equatable { case usb, wifi }
    private enum CaptureState: Equatable {
        case stopped
        case starting
        case capturing
        case interrupted(String)
        case waitingForInput(String)
        case failed(String)
    }
    private var meterTimer: Timer?
    private var activeListenerGeneration: UUID?
    private var activeCaptureRun: AudioCapture.CaptureRun?
    private var captureIntentGeneration: UUID?
    private var captureState: CaptureState = .stopped
    private var selectedTransport: Transport = .usb
    private var routeFingerprint: String?
    private var lastRouteRecoveryFingerprint: String?
    private var routeRecoveryWorkItem: DispatchWorkItem?
    private var lastDiagnosticsRefreshNanoseconds: UInt64 = 0

    init(capture: AudioCaptureControlling = AudioCapture(), link: AudioLinkServer = AudioLinkServer()) {
        self.capture = capture
        self.link = link
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        self.capture = AudioCapture()
        self.link = AudioLinkServer()
        super.init(coder: coder)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildInterface()
        bindCapture()
        refreshPermission()
        startMeterTimer()
        renderCaptureControls()

        NotificationCenter.default.addObserver(
            self, selector: #selector(didEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(willEnterForeground),
            name: UIApplication.willEnterForegroundNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(wasInterrupted),
            name: AVAudioSession.interruptionNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(routeChanged),
            name: AVAudioSession.routeChangeNotification, object: nil
        )
    }

    deinit {
        stopMeterTimer()
        NotificationCenter.default.removeObserver(self)
    }

    private func startMeterTimer() {
        guard meterTimer == nil else { return }
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.refreshMeter()
        }
    }

    private func stopMeterTimer() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    private func buildInterface() {
        let title = UILabel()
        title.text = "CamMic"
        title.font = .preferredFont(forTextStyle: .title2)
        title.adjustsFontForContentSizeCategory = true
        title.numberOfLines = 0

        for label in [permissionLabel, statusLabel, formatLabel, pairingLabel, levelLabel, latencyLabel, diagnosticsLabel] {
            label.font = .preferredFont(forTextStyle: .body)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
        }
        diagnosticsLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.accessibilityIdentifier = "capture.status"
        pairingLabel.font = .monospacedSystemFont(ofSize: 24, weight: .semibold)
        pairingLabel.textAlignment = .center
        meter.progress = 0
        meter.accessibilityLabel = "实时麦克风音量"

        startButton.setTitle("开始 USB 采音", for: .normal)
        stopButton.setTitle("停止采音", for: .normal)
        settingsButton.setTitle("打开系统设置", for: .normal)
        advancedButton.setTitle("高级选项 ▸", for: .normal)
        wifiButton.setTitle("高级：使用 Wi-Fi 配对", for: .normal)
        startButton.addTarget(self, action: #selector(startTapped), for: .touchUpInside)
        stopButton.addTarget(self, action: #selector(stopTapped), for: .touchUpInside)
        settingsButton.addTarget(self, action: #selector(settingsTapped), for: .touchUpInside)
        advancedButton.addTarget(self, action: #selector(advancedTapped), for: .touchUpInside)
        wifiButton.addTarget(self, action: #selector(wifiTapped), for: .touchUpInside)

        advancedStack.axis = .vertical
        advancedStack.spacing = 12
        advancedStack.alignment = .fill
        advancedStack.addArrangedSubview(formatLabel)
        advancedStack.addArrangedSubview(pairingLabel)
        advancedStack.addArrangedSubview(latencyLabel)
        advancedStack.addArrangedSubview(diagnosticsLabel)
        advancedStack.addArrangedSubview(wifiButton)
        advancedStack.isHidden = true

        let controls: [UIView] = [
            title, permissionLabel, statusLabel, levelLabel, meter, startButton, stopButton,
            settingsButton, advancedButton, advancedStack
        ]
        let stack = UIStackView(arrangedSubviews: controls)
        stack.axis = .vertical
        stack.spacing = 18
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 32)
        ])
    }

    private func bindCapture() {
        let audioLink = link
        capture.onAudioFrame = { [weak audioLink] run, capturedAt, pcm in
            audioLink?.sendAudio(
                pcm,
                listenerGeneration: run.listenerGeneration,
                captureRunGeneration: run.generation,
                capturedAtNanoseconds: capturedAt
            )
        }
        capture.onCaptureOverrun = { [weak self] run, diagnostic in
            guard let self = self, self.activeCaptureRun == run else { return }
            let reason: String
            switch diagnostic.reason {
            case .inputFrameExceedsSlot(let actual, let maximum):
                reason = "单个系统音频块有 \(actual) 帧，缓冲槽上限为 \(maximum) 帧。"
            case .bufferLayoutMismatch(let source, let destination):
                reason = "系统音频块有 \(source) 个声道缓冲区，预分配槽有 \(destination) 个。"
            case .missingBufferData(let index):
                reason = "系统音频块第 \(index) 个缓冲区没有可复制的数据。"
            case .bufferBytesExceedSlot(let index, let actual, let maximum):
                reason = "系统音频块第 \(index) 个缓冲区有 \(actual) 字节，槽容量为 \(maximum) 字节。"
            }
            let message = "音频输入队列无法安全接收数据，已断开并清空旧数据。\n诊断：\(reason) 请重新开始。"
            self.failCapture(message: message)
            self.presentCaptureFailure(message)
        }
        capture.onCaptureError = { [weak self] run, error in
            guard let self = self, self.activeCaptureRun == run else { return }
            let message = "音频转换失败：\(error.localizedDescription)"
            self.failCapture(message: message)
            self.presentCaptureFailure(message)
        }
        link.onEvent = { [weak self] event in
            self?.consumeAudioLinkEvent(event)
        }
    }

    func consumeAudioLinkEvent(_ event: AudioLinkServer.Event) {
        precondition(Thread.isMainThread)
        guard captureIntentGeneration != nil,
              activeListenerGeneration == event.listenerGeneration else { return }
        switch event.kind {
        case .status:
            if captureState == .capturing { statusLabel.text = event.message }
        case .listenerFailure:
            failCapture(message: event.message)
            presentCaptureFailure(event.message)
        }
    }

#if DEBUG
    func setCaptureGenerationForTesting(_ generation: UUID?) {
        activeListenerGeneration = generation
        if let generation = generation {
            captureIntentGeneration = UUID()
            if let audioCapture = capture as? AudioCapture {
                activeCaptureRun = AudioCapture.CaptureRun(
                    listenerGeneration: generation,
                    generation: UUID()
                )
                audioCapture.simulatedCaptureForRouteTest = true
            } else {
                activeCaptureRun = try? capture.start(listenerGeneration: generation).run
            }
            captureState = .capturing
        } else {
            captureIntentGeneration = nil
            activeCaptureRun = nil
            (capture as? AudioCapture)?.simulatedCaptureForRouteTest = false
            capture.stop(deactivateSession: true)
            captureState = .stopped
        }
        renderCaptureControls()
    }

    var activeCaptureRunForTesting: AudioCapture.CaptureRun? { activeCaptureRun }
    var captureIntentActiveForTesting: Bool { captureIntentGeneration != nil }
    var inputFormatDescriptionForTesting: String? { formatLabel.text }
    var captureStateDescriptionForTesting: String {
        switch captureState {
        case .stopped: return "stopped"
        case .starting: return "starting"
        case .capturing: return "capturing"
        case .interrupted(let message): return "interrupted: \(message)"
        case .waitingForInput(let message): return "waiting: \(message)"
        case .failed(let message): return "failed: \(message)"
        }
    }

    func handleInterruptionForTesting(type: AVAudioSession.InterruptionType, options: AVAudioSession.InterruptionOptions = []) {
        handleInterruption(type: type, options: options)
    }

    func handleRouteChangeForTesting(reason: AVAudioSession.RouteChangeReason, fingerprint: String) {
        handleRouteChangeOnMain(reason: reason, fingerprint: fingerprint)
    }

    func setRouteFingerprintForTesting(_ fingerprint: String?) {
        routeFingerprint = fingerprint
    }
#endif

    private func refreshPermission() {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            permissionLabel.text = "麦克风权限：已允许"
            settingsButton.isHidden = true
        case .denied:
            permissionLabel.text = "麦克风权限：已拒绝。请到系统设置中允许 CamMic 使用麦克风。"
            settingsButton.isHidden = false
        case .undetermined:
            permissionLabel.text = "麦克风权限：未请求。开始采音时会出现系统授权提示。"
            settingsButton.isHidden = true
        @unknown default:
            permissionLabel.text = "麦克风权限：未知，请检查系统设置。"
            settingsButton.isHidden = false
        }
    }

    @objc private func startTapped() {
        requestCaptureStart(transport: .usb)
    }

    @objc private func wifiTapped() { requestCaptureStart(transport: .wifi) }

    @objc private func advancedTapped() {
        advancedVisible.toggle()
        advancedStack.isHidden = !advancedVisible
        advancedButton.setTitle(advancedVisible ? "高级选项 ▾" : "高级选项 ▸", for: .normal)
    }

    private func requestCaptureStart(transport: Transport) {
        if captureIntentGeneration != nil {
            resumeCaptureFromUser()
            return
        }
        let session = AVAudioSession.sharedInstance()
        if session.recordPermission == .undetermined {
            session.requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    self?.refreshPermission()
                    if granted { self?.startCapture(transport: transport) }
                    else { self?.statusLabel.text = "未获得麦克风权限，采音未开始。" }
                }
            }
        } else {
            refreshPermission()
            startCapture(transport: transport)
        }
    }

    private func startCapture(transport: Transport) {
        guard UIApplication.shared.applicationState == .active else {
            statusLabel.text = "请回到前台后再开始采音。"
            return
        }
        guard captureIntentGeneration == nil else {
            resumeCaptureFromUser()
            return
        }
        captureIntentGeneration = UUID()
        selectedTransport = transport
        captureState = .starting
        renderCaptureControls()
        var stage = transport == .usb ? "准备 USB 连接" : "创建 Wi-Fi 监听器"
        do {
            let listenerRun: AudioLinkServer.ListenerRun
            if transport == .usb {
                listenerRun = try link.startUSB()
            } else {
                listenerRun = try link.start()
            }
            activeListenerGeneration = listenerRun.generation
            stage = "启动麦克风和 48 kHz 音频转换器"
            let captureStart = try capture.start(listenerGeneration: listenerRun.generation)
            activeCaptureRun = captureStart.run
            link.activateCaptureRun(
                listenerGeneration: listenerRun.generation,
                captureRunGeneration: captureStart.run.generation
            )
            if transport == .usb { link.activateUSBListeners(generation: listenerRun.generation) }
            routeFingerprint = Self.inputRouteFingerprint(AVAudioSession.sharedInstance())
            lastRouteRecoveryFingerprint = nil
            pairingLabel.text = transport == .usb
                ? "USB 已启用。Mac 会自动发现 iPhone 并连接，无需输入配对码。"
                : "配对码：\(listenerRun.pairingCode)\n端口：50888"
            formatLabel.text = String(
                format: "输入 %.0f Hz · %u 声道 → 48 kHz · 单声道 PCM16",
                captureStart.inputFormat.sampleRate,
                captureStart.inputFormat.channelCount
            )
            statusLabel.text = transport == .usb
                ? "正在采音。将 iPhone 连接到运行 CamMic 的 Mac 即可自动连接。"
                : "正在采音。请在 Mac 高级 Wi-Fi 连接中输入此配对码。"
            levelLabel.text = "实时电平：等待采样…"
            latencyLabel.text = "Mac 音频设备回调确认 RTT：等待累计确认（不是单向或声学延迟）"
            diagnosticsLabel.text = "采集诊断：等待音频回调。"
            lastDiagnosticsRefreshNanoseconds = 0
            meter.progress = 0
            captureState = .capturing
            renderCaptureControls()
        } catch {
            let message = "无法开始采音（\(stage)）：\(error.localizedDescription)"
            activeListenerGeneration = nil
            activeCaptureRun = nil
            link.stop()
            capture.stop(deactivateSession: true)
            captureIntentGeneration = nil
            captureState = .failed(message)
            pairingLabel.text = "连接已停止。"
            statusLabel.text = message
            renderCaptureControls()
            presentCaptureFailure(message)
        }
    }

    private func resumeCaptureFromUser() {
        precondition(Thread.isMainThread)
        guard let intent = captureIntentGeneration else { return }
        guard captureState != .capturing, captureState != .starting else { return }
        guard let listenerGeneration = activeListenerGeneration else {
            captureIntentGeneration = nil
            startCapture(transport: selectedTransport)
            return
        }
        restoreCapture(intent: intent, listenerGeneration: listenerGeneration, reason: "用户请求恢复")
    }

    private func restoreCapture(intent: UUID, listenerGeneration: UUID, reason: String) {
        precondition(Thread.isMainThread)
        guard captureIntentGeneration == intent,
              activeListenerGeneration == listenerGeneration,
              captureState != .capturing,
              captureState != .starting else { return }
        routeRecoveryWorkItem?.cancel()
        routeRecoveryWorkItem = nil
        captureState = .starting
        renderCaptureControls()
        do {
            let captureStart = try capture.start(listenerGeneration: listenerGeneration)
            guard captureIntentGeneration == intent,
                  activeListenerGeneration == listenerGeneration else {
                capture.stop(deactivateSession: true)
                return
            }
            activeCaptureRun = captureStart.run
            link.activateCaptureRun(
                listenerGeneration: listenerGeneration,
                captureRunGeneration: captureStart.run.generation
            )
            routeFingerprint = Self.inputRouteFingerprint(AVAudioSession.sharedInstance())
            formatLabel.text = String(
                format: "输入 %.0f Hz · %u 声道 → 48 kHz · 单声道 PCM16",
                captureStart.inputFormat.sampleRate,
                captureStart.inputFormat.channelCount
            )
            captureState = .capturing
            statusLabel.text = "采音已恢复（\(reason)）。USB 监听与旧连接状态已隔离，正在发送新的实时音频。"
            lastDiagnosticsRefreshNanoseconds = 0
            meter.progress = 0
            levelLabel.text = "实时电平：等待采样…"
            renderCaptureControls()
        } catch {
            activeCaptureRun = nil
            capture.stop(deactivateSession: true)
            link.suspendCaptureRun(
                listenerGeneration: listenerGeneration,
                captureRunGeneration: nil,
                statusMessage: "音频输入暂不可用，Mac 已静音并清空旧 PCM。"
            )
            capture.deactivateAudioSession()
            let message = "\(reason)后无法恢复音频输入：\(error.localizedDescription)。保留采音意图；等待新的输入路由或你手动恢复。"
            captureState = .waitingForInput(message)
            statusLabel.text = message
            renderCaptureControls()
        }
    }

    private func presentCaptureFailure(_ message: String) {
        guard viewIfLoaded?.window != nil, presentedViewController == nil else { return }
        let alert = UIAlertController(title: "CamMic 采音失败", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default))
        present(alert, animated: true)
    }

    @objc private func stopTapped() {
        cancelRouteRecovery()
        captureIntentGeneration = nil
        activeCaptureRun = nil
        activeListenerGeneration = nil
        link.stop()
        capture.stop(deactivateSession: true)
        routeFingerprint = Self.inputRouteFingerprint(AVAudioSession.sharedInstance())
        captureState = .stopped
        meter.progress = 0
        levelLabel.text = "实时电平：已停止"
        latencyLabel.text = "Mac 音频设备回调确认 RTT：已停止"
        diagnosticsLabel.text = "采集诊断：已停止。"
        pairingLabel.text = "USB 会话已释放；重新开始后会创建新密钥。"
        statusLabel.text = "采音、传输和 USB 监听已由你停止。返回前台或系统中断结束都不会自动重启。"
        renderCaptureControls()
    }

    private func failCapture(message: String) {
        cancelRouteRecovery()
        captureIntentGeneration = nil
        activeCaptureRun = nil
        activeListenerGeneration = nil
        link.stop()
        capture.stop(deactivateSession: true)
        captureState = .failed(message)
        statusLabel.text = message
        renderCaptureControls()
    }

    private func renderCaptureControls() {
        let intentActive = captureIntentGeneration != nil
        let capturing = captureState == .capturing
        startButton.isEnabled = !capturing && captureState != .starting
        stopButton.isEnabled = intentActive || capturing
        wifiButton.isEnabled = !intentActive && captureState != .starting
        if intentActive && !capturing {
            startButton.setTitle("恢复采音", for: .normal)
            stopButton.setTitle("停止采音", for: .normal)
        } else if case .failed = captureState {
            startButton.setTitle("重新开始采音", for: .normal)
            stopButton.isEnabled = false
        } else {
            startButton.setTitle("开始 USB 采音", for: .normal)
            stopButton.setTitle("停止采音", for: .normal)
            if !intentActive { pairingLabel.text = "USB 会话停止后失效。" }
        }
    }

    private func refreshMeter() {
        guard capture.isCapturing else { return }
        let (value, decibels) = capture.levelSnapshot
        meter.setProgress(value, animated: false)
        levelLabel.text = String(format: "实时电平：%.1f dBFS", decibels)

        let now = DispatchTime.now().uptimeNanoseconds
        guard lastDiagnosticsRefreshNanoseconds == 0 ||
                now - lastDiagnosticsRefreshNanoseconds >= 1_000_000_000 else { return }
        lastDiagnosticsRefreshNanoseconds = now
        let metrics = link.metricsSnapshot
        latencyLabel.text = String(
            format: "Mac 音频设备回调确认 RTT：平均 %.1f ms / 最大 %.1f ms · 累计确认 %llu · 在途 %llu/8 · ACK 停滞 %.0f ms（不是单向或声学延迟）",
            metrics.averageRTTMilliseconds,
            metrics.maximumRTTMilliseconds,
            metrics.acknowledgements,
            metrics.inFlight,
            metrics.acknowledgementStallMilliseconds
        )
        if let captureMetrics = capture.diagnosticsSnapshot {
            let queue = captureMetrics.captureQueue
            diagnosticsLabel.text = String(
                format: "采集：回调 %llu 次 · 输入 %llu 帧 · 最大块 %u · 队列 %u/%u/%u 帧 · 采集丢弃 %llu 帧\n排队平均/最大 %.1f/%.1f ms · 转换 %llu 次/%llu 样本 · 平均/最大 %.2f/%.2f ms\n传输：待发 %ld/%ld/8 · 过期丢弃 %llu 帧 · ACK 窗口满 %llu 次",
                queue.callbackCount,
                queue.inputFrames,
                queue.maximumInputBlockFrames,
                queue.bufferedFrames,
                queue.maximumObservedBufferedFrames,
                queue.maximumBufferedFrames,
                queue.droppedFrames,
                queue.averageQueueWaitMilliseconds,
                queue.maximumQueueWaitMilliseconds,
                captureMetrics.conversionCount,
                captureMetrics.convertedSamples,
                captureMetrics.averageConversionMilliseconds,
                captureMetrics.maximumConversionMilliseconds,
                metrics.pendingPackets,
                metrics.pendingHighWaterMark,
                metrics.droppedPackets,
                metrics.acknowledgementWindowFullEvents
            )
        } else {
            diagnosticsLabel.text = "采集诊断：正在等待第一批音频回调。"
        }
    }

    @objc private func settingsTapped() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    @objc private func didEnterBackground() {
        if Thread.isMainThread {
            stopMeterTimer()
        } else {
            DispatchQueue.main.async { [weak self] in self?.stopMeterTimer() }
        }
    }

    @objc private func willEnterForeground() {
        let refresh = { [weak self] in
            guard let self = self else { return }
            self.refreshPermission()
            self.startMeterTimer()
            self.refreshMeter()
        }
        if Thread.isMainThread { refresh() }
        else { DispatchQueue.main.async(execute: refresh) }
    }

    @objc private func wasInterrupted(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: value) else { return }
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            self.handleInterruption(
                type: type,
                options: AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            )
        }
    }

    private func handleInterruption(
        type: AVAudioSession.InterruptionType,
        options: AVAudioSession.InterruptionOptions
    ) {
        precondition(Thread.isMainThread)
        guard let intent = captureIntentGeneration else { return }
        switch type {
        case .began:
            if case .interrupted = captureState { return }
            guard captureState == .capturing || isWaitingForInput else { return }
            cancelRouteRecovery()
            let oldRun = activeCaptureRun
            activeCaptureRun = nil
            capture.stop(deactivateSession: false)
            if let listenerGeneration = activeListenerGeneration {
                link.suspendCaptureRun(
                    listenerGeneration: listenerGeneration,
                    captureRunGeneration: oldRun?.generation,
                    statusMessage: "系统正在使用麦克风；旧音频连接和 PCM 已清空，等待系统允许恢复。"
                )
            }
            let message = "系统音频中断中。采音意图与 USB 监听保留；音频流已停止并清空。"
            captureState = .interrupted(message)
            statusLabel.text = message
            renderCaptureControls()
        case .ended:
            guard case .interrupted = captureState else { return }
            guard captureIntentGeneration == intent else { return }
            if options.contains(.shouldResume), let listenerGeneration = activeListenerGeneration {
                restoreCapture(intent: intent, listenerGeneration: listenerGeneration, reason: "系统中断结束")
            } else {
                capture.deactivateAudioSession()
                let message = "系统中断已结束，但系统未允许自动恢复。采音意图仍保留；可点“恢复采音”，或等待新的音频路由。"
                captureState = .interrupted(message)
                statusLabel.text = message
                renderCaptureControls()
            }
        @unknown default:
            break
        }
    }

    @objc private func routeChanged(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.handleRouteChangeOnMain(
                reason: reason,
                fingerprint: Self.inputRouteFingerprint(AVAudioSession.sharedInstance())
            )
        }
    }

    private var isWaitingForInput: Bool {
        if case .waitingForInput = captureState { return true }
        return false
    }

    private func handleRouteChangeOnMain(_ notification: Notification) {
        precondition(Thread.isMainThread)
        guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        handleRouteChangeOnMain(
            reason: reason,
            fingerprint: Self.inputRouteFingerprint(AVAudioSession.sharedInstance())
        )
    }

    private func handleRouteChangeOnMain(reason: AVAudioSession.RouteChangeReason, fingerprint: String) {
        precondition(Thread.isMainThread)
        switch reason {
        case .oldDeviceUnavailable, .newDeviceAvailable, .categoryChange, .override,
                .wakeFromSleep, .routeConfigurationChange, .noSuitableRouteForCategory, .unknown:
            break
        @unknown default:
            break
        }

        let changed = routeFingerprint != fingerprint
        guard let intent = captureIntentGeneration else {
            routeFingerprint = fingerprint
            return
        }
        if case .interrupted = captureState {
            routeFingerprint = fingerprint
            return
        }
        guard changed else { return }

        routeFingerprint = fingerprint
        lastRouteRecoveryFingerprint = nil
        if captureState == .capturing {
            let oldRun = activeCaptureRun
            activeCaptureRun = nil
            capture.stop(deactivateSession: false)
            if let listenerGeneration = activeListenerGeneration {
                link.suspendCaptureRun(
                    listenerGeneration: listenerGeneration,
                    captureRunGeneration: oldRun?.generation,
                    statusMessage: "输入设备或格式已变化；Mac 已静音并清空旧 PCM。"
                )
            }
            captureState = .waitingForInput("音频输入路由已变化，正在读取新的采样率和声道格式。")
            statusLabel.text = "音频输入路由已变化，正在读取新的采样率和声道格式。"
            renderCaptureControls()
        }
        guard isWaitingForInput, let listenerGeneration = activeListenerGeneration else { return }
        scheduleRouteRecovery(intent: intent, listenerGeneration: listenerGeneration, fingerprint: fingerprint)
    }

    private func scheduleRouteRecovery(intent: UUID, listenerGeneration: UUID, fingerprint: String) {
        guard lastRouteRecoveryFingerprint != fingerprint else { return }
        cancelRouteRecovery()
        lastRouteRecoveryFingerprint = fingerprint
        let work = DispatchWorkItem { [weak self] in
            guard let self = self,
                  self.captureIntentGeneration == intent,
                  self.activeListenerGeneration == listenerGeneration,
                  self.routeFingerprint == fingerprint,
                  self.isWaitingForInput else { return }
            self.routeRecoveryWorkItem = nil
            self.restoreCapture(intent: intent, listenerGeneration: listenerGeneration, reason: "输入路由变化")
        }
        routeRecoveryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250), execute: work)
    }

    private func cancelRouteRecovery() {
        routeRecoveryWorkItem?.cancel()
        routeRecoveryWorkItem = nil
    }

    private static func inputRouteFingerprint(_ session: AVAudioSession) -> String {
        let inputs = session.currentRoute.inputs.map { input in
            "\(input.portType.rawValue):\(input.uid):\(input.channels?.count ?? 0)"
        }.sorted().joined(separator: ",")
        return "\(inputs)|\(session.sampleRate)|\(session.inputNumberOfChannels)"
    }
}
