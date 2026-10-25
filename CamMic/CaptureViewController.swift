import AVFoundation
import UIKit

final class CaptureViewController: UIViewController, AVAudioPlayerDelegate {
    private let capture = AudioCapture()
    private var player: AVAudioPlayer?

    private let permissionLabel = UILabel()
    private let statusLabel = UILabel()
    private let formatLabel = UILabel()
    private let levelLabel = UILabel()
    private let meter = UIProgressView(progressViewStyle: .default)
    private let startButton = UIButton(type: .system)
    private let stopButton = UIButton(type: .system)
    private let playButton = UIButton(type: .system)
    private let settingsButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildInterface()
        bindCapture()
        refreshPermission()
        setCapturing(false)

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

    deinit { NotificationCenter.default.removeObserver(self) }

    private func buildInterface() {
        let title = UILabel()
        title.text = "CamMic · 麦克风验证"
        title.font = .preferredFont(forTextStyle: .title2)
        title.adjustsFontForContentSizeCategory = true
        title.numberOfLines = 0

        for label in [permissionLabel, statusLabel, formatLabel, levelLabel] {
            label.font = .preferredFont(forTextStyle: .body)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
        }
        meter.progress = 0
        meter.accessibilityLabel = "实时麦克风音量"

        startButton.setTitle("开始采集", for: .normal)
        stopButton.setTitle("停止采集", for: .normal)
        playButton.setTitle("回放录音", for: .normal)
        settingsButton.setTitle("打开系统设置", for: .normal)
        startButton.addTarget(self, action: #selector(startTapped), for: .touchUpInside)
        stopButton.addTarget(self, action: #selector(stopTapped), for: .touchUpInside)
        playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        settingsButton.addTarget(self, action: #selector(settingsTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            title, permissionLabel, statusLabel, formatLabel,
            levelLabel, meter, startButton, stopButton, playButton, settingsButton
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
        capture.onLevel = { [weak self] value, decibels in
            guard let self = self, self.capture.isCapturing else { return }
            self.meter.setProgress(value, animated: false)
            self.levelLabel.text = String(format: "实时电平：%.1f dBFS", decibels)
        }
        capture.onRecordingLimit = { [weak self] in
            self?.finishCapture(message: "已录满 12 秒，可回放确认。")
        }
        capture.onCaptureError = { [weak self] error in
            self?.finishCapture(message: "录音失败：\(error.localizedDescription)")
        }
    }

    private func refreshPermission() {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            permissionLabel.text = "麦克风权限：已允许"
            settingsButton.isHidden = true
        case .denied:
            permissionLabel.text = "麦克风权限：已拒绝。请到系统设置中允许 CamMic 使用麦克风。"
            settingsButton.isHidden = false
        case .undetermined:
            permissionLabel.text = "麦克风权限：未请求。开始采集时会出现系统授权提示。"
            settingsButton.isHidden = true
        @unknown default:
            permissionLabel.text = "麦克风权限：未知，请检查系统设置。"
            settingsButton.isHidden = false
        }
    }

    private func setCapturing(_ capturing: Bool) {
        startButton.isEnabled = !capturing
        stopButton.isEnabled = capturing
        playButton.isEnabled = !capturing && capture.recordingURL != nil
    }

    @objc private func startTapped() {
        player?.stop()
        player = nil
        let session = AVAudioSession.sharedInstance()
        if session.recordPermission == .undetermined {
            session.requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    self?.refreshPermission()
                    if granted { self?.startCapture() }
                    else { self?.statusLabel.text = "未获得麦克风权限，采集未开始。" }
                }
            }
        } else {
            refreshPermission()
            startCapture()
        }
    }

    private func startCapture() {
        guard UIApplication.shared.applicationState == .active else {
            statusLabel.text = "请回到前台后再开始采集。"
            return
        }
        do {
            let actual = try capture.start()
            formatLabel.text = String(format: "实际输入：%.0f Hz · %u 声道", actual.sampleRate, actual.channelCount)
            statusLabel.text = "正在采集并录制前 12 秒…"
            levelLabel.text = "实时电平：等待采样…"
            meter.progress = 0
            setCapturing(true)
        } catch {
            statusLabel.text = "无法开始采集：\(error.localizedDescription)"
            setCapturing(false)
        }
    }

    @objc private func stopTapped() { finishCapture(message: "采集已停止，可回放确认。") }

    private func finishCapture(message: String) {
        guard capture.isCapturing else { return }
        capture.stop()
        meter.progress = 0
        levelLabel.text = "实时电平：已停止"
        statusLabel.text = message
        setCapturing(false)
    }

    @objc private func playTapped() {
        guard let url = capture.recordingURL else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.delegate = self
            guard newPlayer.play() else { throw AudioCapture.CaptureError.unavailableInput }
            player = newPlayer
            statusLabel.text = "正在回放录音…"
        } catch {
            statusLabel.text = "无法回放录音：\(error.localizedDescription)"
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        self.player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        statusLabel.text = flag ? "回放结束。" : "回放中断，请重试。"
    }

    @objc private func settingsTapped() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    @objc private func didEnterBackground() {
        finishCapture(message: "进入后台，采集已停止。回到前台可重新开始。")
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    @objc private func willEnterForeground() { refreshPermission() }

    @objc private func wasInterrupted(_ notification: Notification) {
        guard let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              value == AVAudioSession.InterruptionType.began.rawValue else { return }
        finishCapture(message: "音频被系统中断，采集已停止。")
    }

    @objc private func routeChanged(_ notification: Notification) {
        guard capture.isCapturing else { return }
        guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        // Category/activation changes can send a route notification during startup.
        guard reason == .oldDeviceUnavailable || reason == .newDeviceAvailable ||
                reason == .routeConfigurationChange else { return }
        finishCapture(message: "音频输入设备变化，采集已停止。请重新开始。")
    }
}
