import AVFoundation
import UIKit

final class CaptureViewController: UIViewController {
    private let capture: AudioCapture
    private let link: AudioLinkServer

    private let permissionLabel = UILabel()
    private let statusLabel = UILabel()
    private let formatLabel = UILabel()
    private let pairingLabel = UILabel()
    private let levelLabel = UILabel()
    private let latencyLabel = UILabel()
    private let meter = UIProgressView(progressViewStyle: .default)
    private let startButton = UIButton(type: .system)
    private let stopButton = UIButton(type: .system)
    private let settingsButton = UIButton(type: .system)
    private var meterTimer: Timer?
    private var activeListenerGeneration: UUID?

    init(capture: AudioCapture = AudioCapture(), link: AudioLinkServer = AudioLinkServer()) {
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
        setCapturing(false)
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.refreshMeter()
        }

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
        meterTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    private func buildInterface() {
        let title = UILabel()
        title.text = "CamMic · iPhone 麦克风"
        title.font = .preferredFont(forTextStyle: .title2)
        title.adjustsFontForContentSizeCategory = true
        title.numberOfLines = 0

        for label in [permissionLabel, statusLabel, formatLabel, pairingLabel, levelLabel, latencyLabel] {
            label.font = .preferredFont(forTextStyle: .body)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
        }
        statusLabel.accessibilityIdentifier = "capture.status"
        pairingLabel.font = .monospacedSystemFont(ofSize: 24, weight: .semibold)
        pairingLabel.textAlignment = .center
        meter.progress = 0
        meter.accessibilityLabel = "实时麦克风音量"

        startButton.setTitle("开始采音并等待 Mac", for: .normal)
        stopButton.setTitle("停止采音和传输", for: .normal)
        settingsButton.setTitle("打开系统设置", for: .normal)
        startButton.addTarget(self, action: #selector(startTapped), for: .touchUpInside)
        stopButton.addTarget(self, action: #selector(stopTapped), for: .touchUpInside)
        settingsButton.addTarget(self, action: #selector(settingsTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            title, permissionLabel, statusLabel, formatLabel, pairingLabel,
            levelLabel, meter, latencyLabel, startButton, stopButton, settingsButton
        ])
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
        capture.onAudioFrame = { [weak audioLink] listenerGeneration, capturedAt, pcm in
            audioLink?.sendAudio(pcm, listenerGeneration: listenerGeneration, capturedAtNanoseconds: capturedAt)
        }
        capture.onCaptureOverrun = { [weak self] generation, diagnostic in
            guard let self = self, self.activeListenerGeneration == generation else { return }
            let reason: String
            switch diagnostic.reason {
            case .inputFrameExceedsSlot(let actual, let maximum):
                reason = "单个系统音频块有 \(actual) 帧，缓冲槽上限为 \(maximum) 帧。"
            case .bufferedDurationExceeded(let current, let incoming, let maximum):
                reason = "处理队列已有 \(current) 帧，再加入 \(incoming) 帧会超过 \(maximum) 帧的上限。"
            case .noFreeSlot(let occupied):
                reason = "固定缓冲池的 \(occupied) 个槽均在使用中；当前在途 \(diagnostic.bufferedFrames ?? 0)/\(diagnostic.maximumBufferedFrames) 帧。"
            case .bufferLayoutMismatch(let source, let destination):
                reason = "系统音频块有 \(source) 个声道缓冲区，预分配槽有 \(destination) 个。"
            case .missingBufferData(let index):
                reason = "系统音频块第 \(index) 个缓冲区没有可复制的数据。"
            case .bufferBytesExceedSlot(let index, let actual, let maximum):
                reason = "系统音频块第 \(index) 个缓冲区有 \(actual) 字节，槽容量为 \(maximum) 字节。"
            case .stateLockContended:
                reason = "音频回调无法立即取得处理队列锁；为保护实时线程，拒绝了当前块并终止本次采集。"
            }
            let message = "音频输入队列无法安全接收数据，已断开并清空旧数据。\n诊断：\(reason) 请重新开始。"
            self.finishCapture(message: message)
            self.presentCaptureFailure(message)
        }
        capture.onCaptureError = { [weak self] generation, error in
            guard let self = self, self.activeListenerGeneration == generation else { return }
            let message = "音频转换失败：\(error.localizedDescription)"
            self.finishCapture(message: message)
            self.presentCaptureFailure(message)
        }
        link.onEvent = { [weak self] event in
            self?.consumeAudioLinkEvent(event)
        }
    }

    func consumeAudioLinkEvent(_ event: AudioLinkServer.Event) {
        precondition(Thread.isMainThread)
        guard capture.isCapturing,
              activeListenerGeneration == event.listenerGeneration else { return }
        switch event.kind {
        case .status:
            statusLabel.text = event.message
        case .listenerFailure:
            finishCapture(message: event.message)
            presentCaptureFailure(event.message)
        }
    }

#if DEBUG
    func setCaptureGenerationForTesting(_ generation: UUID?) {
        activeListenerGeneration = generation
        capture.simulatedCaptureForRouteTest = generation != nil
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

    private func setCapturing(_ capturing: Bool) {
        startButton.isEnabled = !capturing
        stopButton.isEnabled = capturing
        if !capturing { pairingLabel.text = "配对码：停止后失效" }
    }

    @objc private func startTapped() {
        let session = AVAudioSession.sharedInstance()
        if session.recordPermission == .undetermined {
            session.requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    self?.refreshPermission()
                    if granted { self?.startCapture() }
                    else { self?.statusLabel.text = "未获得麦克风权限，采音未开始。" }
                }
            }
        } else {
            refreshPermission()
            startCapture()
        }
    }

    private func startCapture() {
        guard UIApplication.shared.applicationState == .active else {
            statusLabel.text = "请回到前台后再开始采音。"
            return
        }
        var stage = "创建 iPhone TCP/TLS 监听器"
        do {
            let listenerRun = try link.start()
            activeListenerGeneration = listenerRun.generation
            stage = "启动麦克风和 48 kHz 音频转换器"
            let actual = try capture.start(listenerGeneration: listenerRun.generation)
            UIApplication.shared.isIdleTimerDisabled = true
            pairingLabel.text = "配对码：\(listenerRun.pairingCode)\nTCP 端口：50888"
            formatLabel.text = String(format: "输入 %.0f Hz · %u 声道 → 48 kHz · 单声道 PCM16", actual.sampleRate, actual.channelCount)
            statusLabel.text = "正在采音；在 Mac 输入此配对码并连接。"
            levelLabel.text = "实时电平：等待采样…"
            latencyLabel.text = "Mac 音频设备回调确认 RTT：等待累计确认（不是单向或声学延迟）"
            meter.progress = 0
            setCapturing(true)
        } catch {
            let message = "无法开始采音（\(stage)）：\(error.localizedDescription)"
            activeListenerGeneration = nil
            link.stop()
            capture.stop()
            UIApplication.shared.isIdleTimerDisabled = false
            pairingLabel.text = "配对码：启动失败"
            statusLabel.text = message
            setCapturing(false)
            presentCaptureFailure(message)
        }
    }

    private func presentCaptureFailure(_ message: String) {
        guard viewIfLoaded?.window != nil, presentedViewController == nil else { return }
        let alert = UIAlertController(title: "CamMic 采音失败", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default))
        present(alert, animated: true)
    }

    @objc private func stopTapped() { finishCapture(message: "采音和传输已停止。") }

    private func finishCapture(message: String) {
        guard capture.isCapturing || UIApplication.shared.isIdleTimerDisabled else { return }
        activeListenerGeneration = nil
        link.stop()
        capture.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        meter.progress = 0
        levelLabel.text = "实时电平：已停止"
        latencyLabel.text = "Mac 音频设备回调确认 RTT：已停止"
        statusLabel.text = message
        setCapturing(false)
    }

    private func refreshMeter() {
        guard capture.isCapturing else { return }
        let (value, decibels) = capture.levelSnapshot
        meter.setProgress(value, animated: false)
        levelLabel.text = String(format: "实时电平：%.1f dBFS", decibels)
        let metrics = link.metricsSnapshot
        if metrics.acknowledgements > 0 {
            latencyLabel.text = String(
                format: "Mac 音频设备回调确认 RTT：平均 %.1f ms / 最大 %.1f ms · 累计确认 %llu · 在途 %llu（不是单向或声学延迟）",
                metrics.averageRTTMilliseconds,
                metrics.maximumRTTMilliseconds,
                metrics.acknowledgements,
                metrics.inFlight
            )
        } else {
            latencyLabel.text = "Mac 音频设备回调确认 RTT：等待累计确认（不是单向或声学延迟）"
        }
    }

    @objc private func settingsTapped() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    @objc private func didEnterBackground() {
        finishCapture(message: "进入后台，采音和传输已停止。回到前台可重新开始。")
    }

    @objc private func willEnterForeground() { refreshPermission() }

    @objc private func wasInterrupted(_ notification: Notification) {
        guard let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              value == AVAudioSession.InterruptionType.began.rawValue else { return }
        let message = "音频被系统中断，采音和传输已停止。"
        finishCapture(message: message)
        presentCaptureFailure(message)
    }

    @objc private func routeChanged(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.handleRouteChangeOnMain(notification)
        }
    }

    private func handleRouteChangeOnMain(_ notification: Notification) {
        precondition(Thread.isMainThread)
        guard capture.isCapturing else { return }
        guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        // Category/activation changes can send a route notification during startup.
        guard reason == .oldDeviceUnavailable || reason == .newDeviceAvailable ||
                reason == .routeConfigurationChange else { return }
        let message = "音频输入设备变化，采集已停止。请重新开始。"
        finishCapture(message: message)
        presentCaptureFailure("\(message)（原因码 \(reason.rawValue)）")
    }
}
