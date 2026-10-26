import AVFoundation
import Darwin
import Dispatch
import Foundation
import os.lock

protocol AudioCaptureControlling: AnyObject {
    var onAudioFrame: ((AudioCapture.CaptureRun, UInt64, Data) -> Void)? { get set }
    var onCaptureOverrun: ((AudioCapture.CaptureRun, BoundedPCMQueue.OverrunDiagnostic) -> Void)? { get set }
    var onCaptureError: ((AudioCapture.CaptureRun, Error) -> Void)? { get set }
    var isCapturing: Bool { get }
    var levelSnapshot: (Float, Float) { get }
    var diagnosticsSnapshot: AudioCapture.DiagnosticsSnapshot? { get }
    func start(listenerGeneration: UUID) throws -> AudioCapture.StartResult
    func stop(deactivateSession: Bool)
    func deactivateAudioSession()
}

/// Owns continuous microphone capture. The real-time tap only copies into a fixed pool;
/// conversion and network delivery happen on a separate worker.
final class AudioCapture: AudioCaptureControlling {
    struct CaptureRun: Equatable {
        let listenerGeneration: UUID
        let generation: UUID
    }

    struct InputFormat {
        let sampleRate: Double
        let channelCount: AVAudioChannelCount
    }

    struct StartResult {
        let run: CaptureRun
        let inputFormat: InputFormat
    }

    enum CaptureError: LocalizedError {
        case permissionRequired
        case unavailableInput
        case converterUnavailable
        case workerUnavailable

        var errorDescription: String? {
            switch self {
            case .permissionRequired: return "请先允许 CamMic 使用麦克风。"
            case .unavailableInput: return "没有可用的麦克风输入格式。"
            case .converterUnavailable: return "无法将麦克风音频转换为 48 kHz 单声道 PCM。"
            case .workerUnavailable: return "无法及时启动音频处理线程。"
            }
        }
    }

    var onAudioFrame: ((CaptureRun, UInt64, Data) -> Void)?
    var onCaptureOverrun: ((CaptureRun, BoundedPCMQueue.OverrunDiagnostic) -> Void)?
    var onCaptureError: ((CaptureRun, Error) -> Void)?

    struct DiagnosticsSnapshot {
        let captureQueue: BoundedPCMQueue.MetricsSnapshot
        let conversionCount: UInt64
        let convertedSamples: UInt64
        let averageConversionMilliseconds: Double
        let maximumConversionMilliseconds: Double
    }

    private var engine: AVAudioEngine?
    private var captureQueue: BoundedPCMQueue?
    private let runLock = NSLock()
    private var activeRun: CaptureRun?
    private let levelLock = NSLock()
    private var latestLevelValue: Float = 0
    private var latestDecibelsValue: Float = -80
    private let diagnosticsLock = NSLock()
    private var conversionCount: UInt64 = 0
    private var conversionTotalNanoseconds: UInt64 = 0
    private var maximumConversionNanoseconds: UInt64 = 0
    private var convertedSamples: UInt64 = 0

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

    var diagnosticsSnapshot: DiagnosticsSnapshot? {
        guard let captureQueue = captureQueue else { return nil }
        let queueMetrics = captureQueue.metricsSnapshot
        diagnosticsLock.lock()
        defer { diagnosticsLock.unlock() }
        let average = conversionCount == 0 ? 0 :
            Double(conversionTotalNanoseconds) / Double(conversionCount) / 1_000_000
        return DiagnosticsSnapshot(
            captureQueue: queueMetrics,
            conversionCount: conversionCount,
            convertedSamples: convertedSamples,
            averageConversionMilliseconds: average,
            maximumConversionMilliseconds: Double(maximumConversionNanoseconds) / 1_000_000
        )
    }

    func start(listenerGeneration: UUID) throws -> StartResult {
        precondition(Thread.isMainThread)
        stop(deactivateSession: false)

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

        let pipeline: CapturePCM16Pipeline
        do {
            pipeline = try CapturePCM16Pipeline(
                converter: converter,
                inputFormat: format,
                outputFormat: outputFormat
            )
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }

        let queue = BoundedPCMQueue(
            format: format,
            slotCount: 12,
            maximumFrames: CapturePCM16Pipeline.maximumInputFrames,
            maximumBufferedFrames: AVAudioFrameCount(max(1, format.sampleRate * 0.30))
        )
        let run = CaptureRun(listenerGeneration: listenerGeneration, generation: UUID())
        captureQueue = queue
        diagnosticsLock.lock()
        conversionCount = 0
        conversionTotalNanoseconds = 0
        maximumConversionNanoseconds = 0
        convertedSamples = 0
        diagnosticsLock.unlock()
        runLock.lock()
        activeRun = run
        runLock.unlock()
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak queue, weak self] buffer, _ in
            guard let queue = queue else { return }
            if case .overrun(let diagnostic) = queue.copyFromSystemBuffer(
                buffer,
                capturedAtNanoseconds: DispatchTime.now().uptimeNanoseconds
            ) {
                // The queue coalesces this to one notification per capture run.
                DispatchQueue.main.async { [weak self] in
                    self?.onCaptureOverrun?(run, diagnostic)
                }
            }
        }

        // Start and confirm the bounded consumer before the engine can produce its
        // first tap callbacks. AVAudioEngine.start() may take long enough to fill
        // the fixed pool if the consumer is launched only after it returns.
        let workerReady = DispatchSemaphore(value: 0)
        DispatchQueue(label: "com.yykx682436.CamMic.audio-conversion", qos: .userInitiated)
            .async { [weak self] in
                guard let self = self else {
                    workerReady.signal()
                    return
                }
                self.process(
                    queue: queue,
                    pipeline: pipeline,
                    inputFormat: format,
                    run: run,
                    workerReady: workerReady
                )
            }
        guard workerReady.wait(timeout: .now() + 1) == .success else {
            runLock.lock()
            if activeRun == run { activeRun = nil }
            runLock.unlock()
            input.removeTap(onBus: 0)
            queue.cancelPending()
            captureQueue = nil
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw CaptureError.workerUnavailable
        }

        do {
            try newEngine.start()
            engine = newEngine
        } catch {
            runLock.lock()
            if activeRun == run { activeRun = nil }
            runLock.unlock()
            input.removeTap(onBus: 0)
            queue.cancelPending()
            captureQueue = nil
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
        levelLock.lock()
        latestLevelValue = 0
        latestDecibelsValue = -80
        levelLock.unlock()
        return StartResult(
            run: run,
            inputFormat: InputFormat(sampleRate: format.sampleRate, channelCount: format.channelCount)
        )
    }

    func stop(deactivateSession: Bool = true) {
        precondition(Thread.isMainThread)
        runLock.lock()
        activeRun = nil
        runLock.unlock()
#if DEBUG
        simulatedCaptureForRouteTest = false
#endif
        if let engine = engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            self.engine = nil
        }
        captureQueue?.cancelPending()
        captureQueue = nil
        if deactivateSession { deactivateAudioSession() }
    }

    func deactivateAudioSession() {
        precondition(Thread.isMainThread)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func process(
        queue: BoundedPCMQueue,
        pipeline: CapturePCM16Pipeline,
        inputFormat: AVAudioFormat,
        run: CaptureRun,
        workerReady: DispatchSemaphore
    ) {
        workerReady.signal()
        defer { pipeline.discardPending() }

        while let item = queue.take() {
            guard isCurrent(run) else {
                queue.release(item.index)
                return
            }
            let input = item.buffer
            updateMeter(from: input, format: inputFormat)
            var processingError: Error?
            var frames: [CapturePCM16Pipeline.AudioFrame] = []
            let conversionStartNanoseconds = DispatchTime.now().uptimeNanoseconds
            let convertedSamplesBefore = pipeline.convertedSampleCount
            do {
                frames = try pipeline.append(input, capturedAtNanoseconds: item.capturedAtNanoseconds)
            } catch {
                queue.finish()
                processingError = error
            }
            let conversionEndNanoseconds = DispatchTime.now().uptimeNanoseconds
            recordConversion(
                durationNanoseconds: conversionEndNanoseconds >= conversionStartNanoseconds ?
                    conversionEndNanoseconds - conversionStartNanoseconds : 0,
                outputSamples: pipeline.convertedSampleCount - convertedSamplesBefore
            )
            queue.release(item.index)
            if let error = processingError {
                DispatchQueue.main.async { [weak self] in self?.onCaptureError?(run, error) }
                return
            }
            for frame in frames {
                guard isCurrent(run) else { break }
                onAudioFrame?(run, frame.capturedAtNanoseconds, frame.pcm)
            }
        }
    }

    private func isCurrent(_ run: CaptureRun) -> Bool {
        runLock.lock()
        defer { runLock.unlock() }
        return activeRun == run
    }

    private func recordConversion(durationNanoseconds: UInt64, outputSamples: UInt64) {
        diagnosticsLock.lock()
        conversionCount += 1
        conversionTotalNanoseconds += durationNanoseconds
        maximumConversionNanoseconds = max(maximumConversionNanoseconds, durationNanoseconds)
        convertedSamples += outputSamples
        diagnosticsLock.unlock()
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

    fileprivate static func pcm16LittleEndianData(_ samples: [Int16]) -> Data {
        var bytes = [UInt8](repeating: 0, count: samples.count * MemoryLayout<Int16>.size)
        for index in samples.indices {
            let value = UInt16(bitPattern: samples[index]).littleEndian
            bytes[index * 2] = UInt8(value & 0xFF)
            bytes[index * 2 + 1] = UInt8((value >> 8) & 0xFF)
        }
        return Data(bytes)
    }
}

/// Production conversion and 20 ms framing. The input slot remains owned until
/// `append` has drained every output block the converter can produce from it.
final class CapturePCM16Pipeline {
    struct AudioFrame {
        let capturedAtNanoseconds: UInt64
        let pcm: Data
    }

    enum PipelineError: LocalizedError {
        case invalidInput
        case outputBufferUnavailable
        case outputLimitExceeded
        case converterEndedDuringCapture
        case converterMadeNoProgress
        case converterFailure

        var errorDescription: String? {
            switch self {
            case .invalidInput: return "麦克风输入块超过转换器容量。"
            case .outputBufferUnavailable: return "无法分配有界音频转换输出缓冲。"
            case .outputLimitExceeded: return "音频转换输出超过此输入块的有界样本上限。"
            case .converterEndedDuringCapture: return "音频转换器在采音期间意外结束。"
            case .converterMadeNoProgress: return "音频转换器持续报告数据但没有输出样本。"
            case .converterFailure: return "AVAudioConverter 无法完成 PCM 转换。"
            }
        }
    }

    static let maximumInputFrames: AVAudioFrameCount = 16_384
    private static let maximumBoundedOutputFrames = 131_072
    private static let outputBlockFrames: AVAudioFrameCount = 8_192
    private static let maximumConversionPasses = 32

    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let outputBuffer: AVAudioPCMBuffer
    private let maximumOutputFramesPerInput: Int
    private var converterFinished = false
    private var pendingSamples: [Int16] = []
    private var pendingStartNanoseconds: UInt64?
    private(set) var convertedSampleCount: UInt64 = 0
    var pendingSampleCount: Int { pendingSamples.count }

    init(converter: AVAudioConverter, inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) throws {
        guard inputFormat.sampleRate > 0,
              outputFormat.sampleRate > 0,
              outputFormat.commonFormat == .pcmFormatInt16,
              outputFormat.channelCount == 1 else {
            throw PipelineError.invalidInput
        }
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: Self.outputBlockFrames
        ) else {
            throw PipelineError.outputBufferUnavailable
        }
        let maximumOutputFrames = Int(ceil(
            Double(Self.maximumInputFrames) * outputFormat.sampleRate / inputFormat.sampleRate
        )) + 4_096
        guard maximumOutputFrames <= Self.maximumBoundedOutputFrames else {
            throw PipelineError.invalidInput
        }
        self.converter = converter
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.outputBuffer = outputBuffer
        maximumOutputFramesPerInput = maximumOutputFrames
        pendingSamples.reserveCapacity(Int(CamMicTransport.samplesPerFrame) * 2)
    }

    func append(_ input: AVAudioPCMBuffer, capturedAtNanoseconds: UInt64) throws -> [AudioFrame] {
        guard !converterFinished,
              input.format.isEqual(inputFormat),
              input.frameLength > 0,
              input.frameLength <= Self.maximumInputFrames else {
            throw PipelineError.invalidInput
        }
        let outputLimit = min(
            maximumOutputFramesPerInput,
            Int(ceil(Double(input.frameLength) * outputFormat.sampleRate / inputFormat.sampleRate)) + 4_096
        )
        let samples = try drain(input: input, endOfStream: false, outputLimit: outputLimit)
        return frame(samples, capturedAtNanoseconds: capturedAtNanoseconds)
    }

    /// Flushes the converter's finite resampling tail for tests and orderly teardown.
    /// CamMic only emits complete 960-sample transport frames.
    func finish(capturedAtNanoseconds: UInt64 = 0) throws -> [AudioFrame] {
        guard !converterFinished else { return [] }
        let tailLimit = min(maximumOutputFramesPerInput, 4_096)
        let samples = try drain(input: nil, endOfStream: true, outputLimit: tailLimit)
        converterFinished = true
        return frame(samples, capturedAtNanoseconds: capturedAtNanoseconds)
    }

    func discardPending() {
        pendingSamples.removeAll(keepingCapacity: false)
        pendingStartNanoseconds = nil
    }

    private func drain(
        input: AVAudioPCMBuffer?,
        endOfStream: Bool,
        outputLimit: Int
    ) throws -> [Int16] {
        var suppliedInput = false
        var samples: [Int16] = []
        samples.reserveCapacity(min(outputLimit, Int(Self.outputBlockFrames)))
        var emptyHaveDataPasses = 0

        for _ in 0..<Self.maximumConversionPasses {
            outputBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                if let input = input, !suppliedInput {
                    suppliedInput = true
                    inputStatus.pointee = .haveData
                    return input
                }
                inputStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                return nil
            }

            if status == .error { throw conversionError ?? PipelineError.converterFailure }
            let producedCount = Int(outputBuffer.frameLength)
            if producedCount > 0 {
                guard samples.count <= outputLimit - producedCount,
                      let channel = outputBuffer.int16ChannelData?.pointee else {
                    throw PipelineError.outputLimitExceeded
                }
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: producedCount))
                emptyHaveDataPasses = 0
            }

            switch status {
            case .haveData:
                guard producedCount > 0 else {
                    emptyHaveDataPasses += 1
                    if emptyHaveDataPasses >= 2 { throw PipelineError.converterMadeNoProgress }
                    continue
                }
            case .inputRanDry:
                if endOfStream && producedCount > 0 { continue }
                if producedCount == Int(outputBuffer.frameCapacity) { continue }
                return samples
            case .endOfStream:
                guard endOfStream else { throw PipelineError.converterEndedDuringCapture }
                return samples
            case .error:
                throw conversionError ?? PipelineError.converterFailure
            @unknown default:
                throw PipelineError.converterFailure
            }
        }
        throw PipelineError.outputLimitExceeded
    }

    private func frame(_ samples: [Int16], capturedAtNanoseconds: UInt64) -> [AudioFrame] {
        convertedSampleCount += UInt64(samples.count)
        var frames: [AudioFrame] = []
        frames.reserveCapacity((pendingSamples.count + samples.count) / Int(CamMicTransport.samplesPerFrame))
        for sample in samples {
            if pendingSamples.isEmpty { pendingStartNanoseconds = capturedAtNanoseconds }
            pendingSamples.append(Int16(littleEndian: sample))
            if pendingSamples.count == Int(CamMicTransport.samplesPerFrame) {
                let pcm = AudioCapture.pcm16LittleEndianData(pendingSamples)
                frames.append(AudioFrame(
                    capturedAtNanoseconds: pendingStartNanoseconds ?? capturedAtNanoseconds,
                    pcm: pcm
                ))
                pendingSamples.removeAll(keepingCapacity: true)
                pendingStartNanoseconds = nil
            }
        }
        return frames
    }
}

/// Preallocated SPSC pool. A slot stays owned until the conversion worker releases it.
final class BoundedPCMQueue {
    enum OverrunReason: Equatable {
        case inputFrameExceedsSlot(actual: UInt32, maximum: UInt32)
        case bufferLayoutMismatch(source: UInt32, destination: UInt32)
        case missingBufferData(index: UInt32)
        case bufferBytesExceedSlot(index: UInt32, actual: UInt32, maximum: UInt32)
    }

    struct OverrunDiagnostic: Equatable {
        let reason: OverrunReason
    }

    enum CopyResult: Equatable { case copied, overrun(OverrunDiagnostic), ignored }

    private struct Slot {
        let buffer: AVAudioPCMBuffer
        var state: UInt8 = 0 // free, queued, processing
        var capturedAtNanoseconds: UInt64 = 0
        var frameCount: UInt32 = 0
    }

    private var lock = os_unfair_lock_s()
    private var slots: [Slot] = []
    private var slotCapacities: [[UInt32]] = []
    private var order: [Int]
    private var head = 0
    private var tail = 0
    private var count = 0
    private var bufferedFrames: UInt32 = 0
    private var maximumObservedBufferedFrames: UInt32 = 0
    private var nextFreeSlot = 0
    private var failureNotified: Int32 = 0
    private var stopped = false
    private var callbackCount: Int64 = 0
    private var inputFrameCount: Int64 = 0
    private var droppedFrameCount: Int64 = 0
    private var maximumInputBlockFrames: UInt32 = 0
    private var queueWaitSampleCount: UInt64 = 0
    private var queueWaitTotalNanoseconds: UInt64 = 0
    private var maximumQueueWaitNanoseconds: UInt64 = 0
    private var workerWakePending = false
    private let wakeWorker = DispatchSemaphore(value: 0)
    private let maximumBufferedFrames: UInt32

    struct MetricsSnapshot {
        let callbackCount: UInt64
        let inputFrames: UInt64
        let droppedFrames: UInt64
        let maximumInputBlockFrames: UInt32
        let bufferedFrames: UInt32
        let maximumObservedBufferedFrames: UInt32
        let maximumBufferedFrames: UInt32
        let averageQueueWaitMilliseconds: Double
        let maximumQueueWaitMilliseconds: Double
    }

    init(
        format: AVAudioFormat,
        slotCount: Int,
        maximumFrames: AVAudioFrameCount,
        maximumBufferedFrames: AVAudioFrameCount
    ) {
        precondition(slotCount > 0 && maximumFrames > 0 && maximumBufferedFrames > 0)
        order = [Int](repeating: 0, count: slotCount)
        self.maximumBufferedFrames = maximumBufferedFrames
        for _ in 0..<slotCount {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maximumFrames) else {
                preconditionFailure("Unable to allocate bounded microphone buffer pool")
            }
            slots.append(Slot(buffer: buffer))
            let bytesPerBuffer = UInt32(maximumFrames) * format.streamDescription.pointee.mBytesPerFrame
            slotCapacities.append(
                UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
                    .map { max($0.mDataByteSize, bytesPerBuffer) }
            )
        }
    }

    func copyFromSystemBuffer(_ source: AVAudioPCMBuffer, capturedAtNanoseconds: UInt64) -> CopyResult {
        guard os_unfair_lock_trylock(&lock) else {
            OSAtomicIncrement64Barrier(&callbackCount)
            OSAtomicAdd64Barrier(Int64(source.frameLength), &inputFrameCount)
            OSAtomicAdd64Barrier(Int64(source.frameLength), &droppedFrameCount)
            return .ignored
        }
        defer { os_unfair_lock_unlock(&lock) }
        guard !stopped, OSAtomicCompareAndSwap32Barrier(0, 0, &failureNotified) else { return .ignored }
        guard source.frameLength > 0 else { return .ignored }
        OSAtomicIncrement64Barrier(&callbackCount)
        OSAtomicAdd64Barrier(Int64(source.frameLength), &inputFrameCount)
        maximumInputBlockFrames = max(maximumInputBlockFrames, source.frameLength)
        guard source.frameLength <= slots[0].buffer.frameCapacity else {
            return markOverrun(.inputFrameExceedsSlot(
                actual: source.frameLength,
                maximum: slots[0].buffer.frameCapacity
            ), rejectedFrames: source.frameLength)
        }
        guard source.frameLength <= maximumBufferedFrames else {
            OSAtomicAdd64Barrier(Int64(source.frameLength), &droppedFrameCount)
            return .ignored
        }
        while source.frameLength > maximumBufferedFrames - min(bufferedFrames, maximumBufferedFrames) {
            guard dropOldestQueuedSlot() else {
                // The only audio left may be owned by the converter. Keep the
                // callback real-time safe and discard this already-expired block.
                OSAtomicAdd64Barrier(Int64(source.frameLength), &droppedFrameCount)
                return .ignored
            }
        }
        var selected: Int?
        for offset in 0..<slots.count {
            let index = (nextFreeSlot + offset) % slots.count
            if slots[index].state == 0 { selected = index; break }
        }
        while selected == nil, dropOldestQueuedSlot() {
            for offset in 0..<slots.count {
                let index = (nextFreeSlot + offset) % slots.count
                if slots[index].state == 0 { selected = index; break }
            }
        }
        guard let index = selected else {
            OSAtomicAdd64Barrier(Int64(source.frameLength), &droppedFrameCount)
            return .ignored
        }
        // The mutable wrapper is only a view here; source buffer metadata and samples stay read-only.
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        let destination = slots[index].buffer
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else {
            return markOverrun(.bufferLayoutMismatch(
                source: UInt32(sourceBuffers.count),
                destination: UInt32(destinationBuffers.count)
            ), rejectedFrames: source.frameLength)
        }
        for bufferIndex in sourceBuffers.indices {
            let sourceBuffer = sourceBuffers[bufferIndex]
            let destinationBuffer = destinationBuffers[bufferIndex]
            guard let sourceData = sourceBuffer.mData, let destinationData = destinationBuffer.mData else {
                return markOverrun(.missingBufferData(index: UInt32(bufferIndex)), rejectedFrames: source.frameLength)
            }
            guard sourceBuffer.mDataByteSize <= slotCapacities[index][bufferIndex] else {
                return markOverrun(.bufferBytesExceedSlot(
                    index: UInt32(bufferIndex),
                    actual: sourceBuffer.mDataByteSize,
                    maximum: slotCapacities[index][bufferIndex]
                ), rejectedFrames: source.frameLength)
            }
            memcpy(destinationData, sourceData, Int(sourceBuffer.mDataByteSize))
            destinationBuffers[bufferIndex].mDataByteSize = sourceBuffer.mDataByteSize
        }
        destination.frameLength = source.frameLength
        slots[index].state = 1
        slots[index].frameCount = source.frameLength
        bufferedFrames += source.frameLength
        maximumObservedBufferedFrames = max(maximumObservedBufferedFrames, bufferedFrames)
        slots[index].capturedAtNanoseconds = capturedAtNanoseconds
        order[tail] = index
        tail = (tail + 1) % order.count
        count += 1
        nextFreeSlot = (index + 1) % slots.count
        if !workerWakePending {
            workerWakePending = true
            wakeWorker.signal()
        }
        return .copied
    }

    func take() -> (index: Int, buffer: AVAudioPCMBuffer, capturedAtNanoseconds: UInt64)? {
        while true {
            wakeWorker.wait()
            os_unfair_lock_lock(&lock)
            workerWakePending = false
            if count > 0 {
                let index = order[head]
                head = (head + 1) % order.count
                count -= 1
                slots[index].state = 2
                let buffer = slots[index].buffer
                let capturedAtNanoseconds = slots[index].capturedAtNanoseconds
                let now = DispatchTime.now().uptimeNanoseconds
                if now >= capturedAtNanoseconds {
                    let wait = now - capturedAtNanoseconds
                    queueWaitSampleCount += 1
                    queueWaitTotalNanoseconds += wait
                    maximumQueueWaitNanoseconds = max(maximumQueueWaitNanoseconds, wait)
                }
                if count > 0 || stopped {
                    workerWakePending = true
                    wakeWorker.signal()
                }
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
        bufferedFrames -= slots[index].frameCount
        slots[index].frameCount = 0
        slots[index].state = 0
        os_unfair_lock_unlock(&lock)
    }

    func finish() {
        os_unfair_lock_lock(&lock)
        stopped = true
        if !workerWakePending {
            workerWakePending = true
            wakeWorker.signal()
        }
        os_unfair_lock_unlock(&lock)
    }

    /// Stops the worker and drops audio that has not yet entered the converter.
    /// A slot currently owned by the converter is released when that bounded
    /// conversion pass returns and observes its invalidated capture run.
    func cancelPending() {
        os_unfair_lock_lock(&lock)
        stopped = true
        while count > 0 {
            let index = order[head]
            head = (head + 1) % order.count
            count -= 1
            if slots[index].state == 1 {
                bufferedFrames -= slots[index].frameCount
                slots[index].frameCount = 0
                slots[index].state = 0
                slots[index].buffer.frameLength = 0
            }
        }
        tail = head
        if !workerWakePending {
            workerWakePending = true
            wakeWorker.signal()
        }
        os_unfair_lock_unlock(&lock)
    }

    private func markOverrun(_ reason: OverrunReason, rejectedFrames: UInt32) -> CopyResult {
        guard OSAtomicCompareAndSwap32Barrier(0, 1, &failureNotified) else { return .ignored }
        OSAtomicAdd64Barrier(Int64(rejectedFrames), &droppedFrameCount)
        return .overrun(OverrunDiagnostic(reason: reason))
    }

    /// Releases the oldest queued slot. A slot currently owned by the converter
    /// is never reclaimed.
    private func dropOldestQueuedSlot() -> Bool {
        guard count > 0 else { return false }
        let index = order[head]
        guard slots[index].state == 1 else { return false }
        head = (head + 1) % order.count
        count -= 1
        let frames = slots[index].frameCount
        bufferedFrames -= frames
        slots[index].frameCount = 0
        slots[index].state = 0
        OSAtomicAdd64Barrier(Int64(frames), &droppedFrameCount)
        return true
    }

    var metricsSnapshot: MetricsSnapshot {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let callbacks = UInt64(max(0, OSAtomicAdd64Barrier(0, &callbackCount)))
        let inputFrames = UInt64(max(0, OSAtomicAdd64Barrier(0, &inputFrameCount)))
        let droppedFrames = UInt64(max(0, OSAtomicAdd64Barrier(0, &droppedFrameCount)))
        let averageWait = queueWaitSampleCount == 0 ? 0 :
            Double(queueWaitTotalNanoseconds) / Double(queueWaitSampleCount) / 1_000_000
        return MetricsSnapshot(
            callbackCount: callbacks,
            inputFrames: inputFrames,
            droppedFrames: droppedFrames,
            maximumInputBlockFrames: maximumInputBlockFrames,
            bufferedFrames: bufferedFrames,
            maximumObservedBufferedFrames: maximumObservedBufferedFrames,
            maximumBufferedFrames: maximumBufferedFrames,
            averageQueueWaitMilliseconds: averageWait,
            maximumQueueWaitMilliseconds: Double(maximumQueueWaitNanoseconds) / 1_000_000
        )
    }

#if DEBUG
    func holdStateLockForTesting(
        acquired: DispatchSemaphore,
        release: DispatchSemaphore,
        finished: DispatchSemaphore
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            os_unfair_lock_lock(&self.lock)
            acquired.signal()
            release.wait()
            os_unfair_lock_unlock(&self.lock)
            finished.signal()
        }
    }

    var bufferedFramesForTesting: UInt32 {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return bufferedFrames
    }

    var droppedFramesForTesting: UInt64 { metricsSnapshot.droppedFrames }
#endif
}

private enum CamMicTransport {
    static let sampleRate = CamMicFrameCodec.sampleRate
    static let samplesPerFrame = CamMicFrameCodec.samplesPerFrame
}
