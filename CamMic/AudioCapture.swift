import AVFoundation
import Dispatch
import Foundation
import os.lock

/// Owns continuous microphone capture. The real-time tap only copies into a fixed pool;
/// conversion and network delivery happen on a separate worker.
final class AudioCapture {
    struct InputFormat {
        let sampleRate: Double
        let channelCount: AVAudioChannelCount
    }

    enum CaptureError: LocalizedError {
        case permissionRequired
        case unavailableInput
        case converterUnavailable

        var errorDescription: String? {
            switch self {
            case .permissionRequired: return "请先允许 CamMic 使用麦克风。"
            case .unavailableInput: return "没有可用的麦克风输入格式。"
            case .converterUnavailable: return "无法将麦克风音频转换为 48 kHz 单声道 PCM。"
            }
        }
    }

    var onAudioFrame: ((UUID, UInt64, Data) -> Void)?
    var onCaptureOverrun: ((UUID) -> Void)?
    var onCaptureError: ((UUID, Error) -> Void)?

    private var engine: AVAudioEngine?
    private var captureQueue: BoundedPCMQueue?
    private let runLock = NSLock()
    private var activeListenerGeneration: UUID?
    private let levelLock = NSLock()
    private var latestLevelValue: Float = 0
    private var latestDecibelsValue: Float = -80

#if DEBUG
    // Drives the real stop path in the route-notification regression without a microphone.
    var simulatedCaptureForRouteTest = false
#endif

    var isCapturing: Bool {
#if DEBUG
        return engine != nil || simulatedCaptureForRouteTest
#else
        return engine != nil
#endif
    }

    var levelSnapshot: (Float, Float) {
        levelLock.lock()
        defer { levelLock.unlock() }
        return (latestLevelValue, latestDecibelsValue)
    }

    func start(listenerGeneration: UUID) throws -> InputFormat {
        precondition(Thread.isMainThread)
        stop()

        let session = AVAudioSession.sharedInstance()
        guard session.recordPermission == .granted else { throw CaptureError.permissionRequired }
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)

        let newEngine = AVAudioEngine()
        let input = newEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw CaptureError.unavailableInput
        }
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(CamMicTransport.sampleRate),
            channels: 1,
            interleaved: false
        )!
        guard let converter = AVAudioConverter(from: format, to: outputFormat) else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw CaptureError.converterUnavailable
        }

        let queue = BoundedPCMQueue(format: format, slotCount: 8, maximumFrames: 4096)
        captureQueue = queue
        runLock.lock()
        activeListenerGeneration = listenerGeneration
        runLock.unlock()
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak queue, weak self] buffer, _ in
            guard let queue = queue else { return }
            if queue.copyFromSystemBuffer(buffer, capturedAtNanoseconds: DispatchTime.now().uptimeNanoseconds) == .overrun {
                // The queue coalesces this to one notification per capture run.
                DispatchQueue.main.async { [weak self] in self?.onCaptureOverrun?(listenerGeneration) }
            }
        }
        do {
            try newEngine.start()
            engine = newEngine
            DispatchQueue(label: "com.yykx682436.CamMic.audio-conversion", qos: .userInitiated)
                .async { [weak self] in
                    self?.process(
                        queue: queue,
                        converter: converter,
                        inputFormat: format,
                        outputFormat: outputFormat,
                        listenerGeneration: listenerGeneration
                    )
                }
        } catch {
            input.removeTap(onBus: 0)
            queue.finish()
            captureQueue = nil
            runLock.lock()
            activeListenerGeneration = nil
            runLock.unlock()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
        levelLock.lock()
        latestLevelValue = 0
        latestDecibelsValue = -80
        levelLock.unlock()
        return InputFormat(sampleRate: format.sampleRate, channelCount: format.channelCount)
    }

    func stop() {
        precondition(Thread.isMainThread)
        runLock.lock()
        activeListenerGeneration = nil
        runLock.unlock()
#if DEBUG
        simulatedCaptureForRouteTest = false
#endif
        if let engine = engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            self.engine = nil
        }
        captureQueue?.finish()
        captureQueue = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func process(
        queue: BoundedPCMQueue,
        converter: AVAudioConverter,
        inputFormat: AVAudioFormat,
        outputFormat: AVAudioFormat,
        listenerGeneration: UUID
    ) {
        var pendingSamples: [Int16] = []
        pendingSamples.reserveCapacity(Int(CamMicTransport.samplesPerFrame) * 2)
        var pendingStartNanoseconds: UInt64?

        while let item = queue.take() {
            guard isCurrent(listenerGeneration) else {
                queue.release(item.index)
                return
            }
            let input = item.buffer
            updateMeter(from: input, format: inputFormat)
            var processingError: Error?
            do {
                let expected = Int(ceil(Double(input.frameLength) * outputFormat.sampleRate / inputFormat.sampleRate)) + 256
                guard let converted = AVAudioPCMBuffer(
                    pcmFormat: outputFormat,
                    frameCapacity: AVAudioFrameCount(min(max(expected, 1024), 8192))
                ) else { throw CaptureError.converterUnavailable }
                var suppliedInput = false
                var conversionError: NSError?
                let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
                    guard !suppliedInput else {
                        inputStatus.pointee = .noDataNow
                        return nil
                    }
                    suppliedInput = true
                    inputStatus.pointee = .haveData
                    return input
                }
                if status == .error { throw conversionError ?? CaptureError.converterUnavailable }
                if let samples = converted.int16ChannelData?.pointee, converted.frameLength > 0 {
                    for index in 0..<Int(converted.frameLength) {
                        if pendingSamples.isEmpty { pendingStartNanoseconds = item.capturedAtNanoseconds }
                        pendingSamples.append(Int16(littleEndian: samples[index]))
                        if pendingSamples.count == Int(CamMicTransport.samplesPerFrame) {
                            if isCurrent(listenerGeneration), let capturedAt = pendingStartNanoseconds {
                                onAudioFrame?(listenerGeneration, capturedAt, Self.pcm16LittleEndianData(pendingSamples))
                            }
                            pendingSamples.removeAll(keepingCapacity: true)
                            pendingStartNanoseconds = nil
                        }
                    }
                }
            } catch {
                queue.finish()
                processingError = error
            }
            queue.release(item.index)
            if let error = processingError {
                DispatchQueue.main.async { [weak self] in self?.onCaptureError?(listenerGeneration, error) }
                return
            }
        }
    }

    private func isCurrent(_ listenerGeneration: UUID) -> Bool {
        runLock.lock()
        defer { runLock.unlock() }
        return activeListenerGeneration == listenerGeneration
    }

    private func updateMeter(from buffer: AVAudioPCMBuffer, format: AVAudioFormat) {
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        guard frames > 0, channels > 0 else { return }
        var sum: Double = 0
        for channel in 0..<channels {
            if let data = buffer.floatChannelData {
                for frame in 0..<frames {
                    let sample = Double(data[channel][frame])
                    sum += sample * sample
                }
            } else if let data = buffer.int16ChannelData {
                for frame in 0..<frames {
                    let sample = Double(data[channel][frame]) / 32768.0
                    sum += sample * sample
                }
            } else if let data = buffer.int32ChannelData {
                for frame in 0..<frames {
                    let sample = Double(data[channel][frame]) / 2147483648.0
                    sum += sample * sample
                }
            } else {
                return
            }
        }
        let rms = sqrt(sum / Double(frames * channels))
        let decibels = Float(max(-80, 20 * log10(max(rms, 0.0001))))
        let normalized = Float(max(0, min(1, (Double(decibels) + 60) / 60)))
        levelLock.lock()
        latestLevelValue = normalized
        latestDecibelsValue = decibels
        levelLock.unlock()
    }

    private static func pcm16LittleEndianData(_ samples: [Int16]) -> Data {
        var bytes = [UInt8](repeating: 0, count: samples.count * MemoryLayout<Int16>.size)
        for index in samples.indices {
            let value = UInt16(bitPattern: samples[index]).littleEndian
            bytes[index * 2] = UInt8(value & 0xFF)
            bytes[index * 2 + 1] = UInt8((value >> 8) & 0xFF)
        }
        return Data(bytes)
    }
}

/// Preallocated SPSC pool. A slot stays owned until the conversion worker releases it.
private final class BoundedPCMQueue {
    enum CopyResult: Equatable { case copied, overrun, ignored }

    private struct Slot {
        let buffer: AVAudioPCMBuffer
        var state: UInt8 = 0 // free, queued, processing
        var capturedAtNanoseconds: UInt64 = 0
    }

    private var lock = os_unfair_lock_s()
    private var slots: [Slot] = []
    private var slotCapacities: [[UInt32]] = []
    private var order: [Int]
    private var head = 0
    private var tail = 0
    private var count = 0
    private var nextFreeSlot = 0
    private var overflowNotified = false
    private var stopped = false
    private let wakeWorker = DispatchSemaphore(value: 0)

    init(format: AVAudioFormat, slotCount: Int, maximumFrames: AVAudioFrameCount) {
        order = [Int](repeating: 0, count: slotCount)
        for _ in 0..<slotCount {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maximumFrames) else {
                preconditionFailure("Unable to allocate bounded microphone buffer pool")
            }
            slots.append(Slot(buffer: buffer))
            let bytesPerBuffer = UInt32(maximumFrames) * format.streamDescription.pointee.mBytesPerFrame
            slotCapacities.append(
                UnsafeMutableAudioBufferListPointer(buffer.audioBufferList).map { max($0.mDataByteSize, bytesPerBuffer) }
            )
        }
    }

    func copyFromSystemBuffer(_ source: AVAudioPCMBuffer, capturedAtNanoseconds: UInt64) -> CopyResult {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard !stopped else { return .ignored }
        guard source.frameLength > 0, source.frameLength <= slots[0].buffer.frameCapacity else { return markOverrun() }
        var selected: Int?
        for offset in 0..<slots.count {
            let index = (nextFreeSlot + offset) % slots.count
            if slots[index].state == 0 { selected = index; break }
        }
        guard let index = selected else { return markOverrun() }
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.audioBufferList)
        let destination = slots[index].buffer
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return markOverrun() }
        for bufferIndex in sourceBuffers.indices {
            let sourceBuffer = sourceBuffers[bufferIndex]
            let destinationBuffer = destinationBuffers[bufferIndex]
            guard let sourceData = sourceBuffer.mData, let destinationData = destinationBuffer.mData,
                  sourceBuffer.mDataByteSize <= slotCapacities[index][bufferIndex] else {
                return markOverrun()
            }
            memcpy(destinationData, sourceData, Int(sourceBuffer.mDataByteSize))
            destinationBuffers[bufferIndex].mDataByteSize = sourceBuffer.mDataByteSize
        }
        destination.frameLength = source.frameLength
        slots[index].state = 1
        slots[index].capturedAtNanoseconds = capturedAtNanoseconds
        order[tail] = index
        tail = (tail + 1) % order.count
        count += 1
        nextFreeSlot = (index + 1) % slots.count
        wakeWorker.signal()
        return .copied
    }

    func take() -> (index: Int, buffer: AVAudioPCMBuffer, capturedAtNanoseconds: UInt64)? {
        while true {
            wakeWorker.wait()
            os_unfair_lock_lock(&lock)
            if count > 0 {
                let index = order[head]
                head = (head + 1) % order.count
                count -= 1
                slots[index].state = 2
                let buffer = slots[index].buffer
                let capturedAtNanoseconds = slots[index].capturedAtNanoseconds
                os_unfair_lock_unlock(&lock)
                return (index, buffer, capturedAtNanoseconds)
            }
            let shouldStop = stopped
            os_unfair_lock_unlock(&lock)
            if shouldStop { return nil }
        }
    }

    func release(_ index: Int) {
        os_unfair_lock_lock(&lock)
        slots[index].state = 0
        os_unfair_lock_unlock(&lock)
    }

    func finish() {
        os_unfair_lock_lock(&lock)
        stopped = true
        os_unfair_lock_unlock(&lock)
        wakeWorker.signal()
    }

    private func markOverrun() -> CopyResult {
        guard !overflowNotified else { return .ignored }
        overflowNotified = true
        return .overrun
    }
}

private enum CamMicTransport {
    static let sampleRate = CamMicFrameCodec.sampleRate
    static let samplesPerFrame = CamMicFrameCodec.samplesPerFrame
}
