import AVFoundation
import Foundation

/// Owns the microphone session, live PCM tap, and short local recording.
final class AudioCapture {
    struct InputFormat {
        let sampleRate: Double
        let channelCount: AVAudioChannelCount
    }

    enum CaptureError: LocalizedError {
        case permissionRequired
        case unavailableInput

        var errorDescription: String? {
            switch self {
            case .permissionRequired: return "请先允许 CamMic 使用麦克风。"
            case .unavailableInput: return "没有可用的麦克风输入格式。"
            }
        }
    }

    /// Called on the audio tap thread. A future sender must copy data before returning.
    var onPCMBuffer: ((AVAudioPCMBuffer, AVAudioFormat) -> Void)?
    /// Delivered on the main queue, at most about ten times per second.
    var onLevel: ((Float, Float) -> Void)?
    var onRecordingLimit: (() -> Void)?
    var onCaptureError: ((Error) -> Void)?

    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var file: AVAudioFile?
    private(set) var recordingURL: URL?
    private var recordedFrames: AVAudioFramePosition = 0
    private var frameLimit: AVAudioFramePosition = 0
    private var lastMeterTime: TimeInterval = 0
    private var stopRequested = false

    var isCapturing: Bool { engine != nil }

    func start() throws -> InputFormat {
        precondition(Thread.isMainThread)
        stop()
        recordingURL = nil

        let session = AVAudioSession.sharedInstance()
        guard session.recordPermission == .granted else {
            throw CaptureError.permissionRequired
        }

        try session.setCategory(.record, mode: .default)
        try session.setActive(true)

        let newEngine = AVAudioEngine()
        let input = newEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw CaptureError.unavailableInput
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CamMic-recording.caf")
        do {
            try? FileManager.default.removeItem(at: url)
            let newFile = try AVAudioFile(forWriting: url, settings: format.settings)
            lock.lock()
            file = newFile
            recordedFrames = 0
            frameLimit = AVAudioFramePosition(format.sampleRate * 12)
            lastMeterTime = 0
            stopRequested = false
            lock.unlock()

            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.handle(buffer, format: format)
            }
            try newEngine.start()
            engine = newEngine
            recordingURL = url
            return InputFormat(sampleRate: format.sampleRate, channelCount: format.channelCount)
        } catch {
            input.removeTap(onBus: 0)
            newEngine.stop()
            lock.lock()
            file = nil
            lock.unlock()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
    }

    func stop() {
        precondition(Thread.isMainThread)
        if let engine = engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            self.engine = nil
        }
        lock.lock()
        file = nil
        lock.unlock()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func handle(_ buffer: AVAudioPCMBuffer, format: AVAudioFormat) {
        // The callback exposes the original device samples, not a requested format.
        onPCMBuffer?(buffer, format)

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }
        let channelCount = Int(format.channelCount)
        var sum: Double = 0
        var count = 0
        for channel in 0..<channelCount {
            if let data = buffer.floatChannelData {
                for frame in 0..<frameCount {
                    let sample = Double(data[channel][frame])
                    sum += sample * sample
                }
            } else if let data = buffer.int16ChannelData {
                for frame in 0..<frameCount {
                    let sample = Double(data[channel][frame]) / 32768.0
                    sum += sample * sample
                }
            } else if let data = buffer.int32ChannelData {
                for frame in 0..<frameCount {
                    let sample = Double(data[channel][frame]) / 2147483648.0
                    sum += sample * sample
                }
            } else {
                return
            }
            count += frameCount
        }
        let rms = sqrt(sum / Double(count))
        let decibels = Float(max(-80, 20 * log10(max(rms, 0.0001))))
        let normalized = Float(max(0, min(1, (Double(decibels) + 60) / 60)))

        var shouldUpdateLevel = false
        var reachedLimit = false
        var writeError: Error?
        lock.lock()
        if let file = file, !stopRequested {
            do {
                try file.write(from: buffer)
                recordedFrames += AVAudioFramePosition(buffer.frameLength)
                if recordedFrames >= frameLimit {
                    stopRequested = true
                    reachedLimit = true
                }
            } catch {
                stopRequested = true
                writeError = error
            }
            let now = Date.timeIntervalSinceReferenceDate
            if now - lastMeterTime >= 0.1 {
                lastMeterTime = now
                shouldUpdateLevel = true
            }
        }
        lock.unlock()

        if shouldUpdateLevel {
            DispatchQueue.main.async { [weak self] in self?.onLevel?(normalized, decibels) }
        }
        if reachedLimit {
            DispatchQueue.main.async { [weak self] in self?.onRecordingLimit?() }
        }
        if let error = writeError {
            DispatchQueue.main.async { [weak self] in self?.onCaptureError?(error) }
        }
    }
}
