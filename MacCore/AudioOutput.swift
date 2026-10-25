import AVFoundation
import CamMicShared
import CoreAudio
import Darwin
import Foundation
import os.lock

public struct AudioOutputDevice {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let sampleRate: Double
    public let channelCount: UInt32
    public let format: AudioStreamBasicDescription

    public var displayName: String { "\(name) · \(Int(sampleRate)) Hz · \(channelCount) ch" }

    public init(
        id: AudioDeviceID,
        uid: String,
        name: String,
        sampleRate: Double,
        channelCount: UInt32,
        format: AudioStreamBasicDescription
    ) {
        self.id = id
        self.uid = uid
        self.name = name
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.format = format
    }
}

public enum AudioDeviceError: LocalizedError {
    case deviceList(OSStatus)
    case noOutputDevices
    case missingCamMic
    case missingDevice
    case noStereoOutput
    case unsupportedFormat
    case coreAudio(OSStatus)
    case conversionFailed
    case queueFull

    public var errorDescription: String? {
        switch self {
        case .deviceList(let status): return "无法读取系统音频设备（CoreAudio \(status)）。"
        case .noOutputDevices: return "没有可用的双声道音频输出端。"
        case .missingCamMic: return "未检测到完整的 CamMic 音频组件。请安装或修复 CamMic 驱动后再连接。"
        case .missingDevice: return "CamMic 内部输出端已不存在。"
        case .noStereoOutput: return "CamMic 内部输出端没有至少两个输出声道。"
        case .unsupportedFormat: return "CamMic 内部输出端格式暂不受支持。"
        case .coreAudio(let status): return "无法启动 CamMic 内部输出端（CoreAudio \(status)）。"
        case .conversionFailed: return "无法将接收的 PCM 转换为 CamMic 内部输出格式。"
        case .queueFull: return "Mac 播放缓冲已满，连接将重置以清除积压音频。"
        }
    }
}

/// Direct CoreAudio output to the chosen device UID. Its callback only drains a fixed ring and writes silence on underrun.
public final class AudioDeviceOutput {
    private final class Slot {
        let samples: UnsafeMutablePointer<Float>
        let capacity: Int
        var frameCount = 0
        var sequence: UInt64 = 0

        init(capacity: Int) {
            self.capacity = capacity
            samples = .allocate(capacity: capacity)
            samples.initialize(repeating: 0, count: capacity)
        }

        deinit {
            samples.deinitialize(count: capacity)
            samples.deallocate()
        }
    }

    public let device: AudioOutputDevice
    private let capacity = 12
    private let slotSampleCapacity = 4096
    private var slots: [Slot] = []
    private var head = 0
    private var tail = 0
    private var count = 0
    private var offset = 0
    private var queuedFrames = 0
    private var lastConsumed: UInt64 = 0
    private var underruns: UInt64 = 0
    private var renderContentionCallbacks: Int64 = 0
    private var renderLock = os_unfair_lock_s()
    private let enqueueLock = NSLock()
    private var ioProcID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var driftCorrection = 0.0
    private var started = false
    private var playbackActive = false

    public init(device: AudioOutputDevice) throws {
        self.device = device
        guard device.channelCount >= 2 else { throw AudioDeviceError.noStereoOutput }
        let flags = device.format.mFormatFlags
        let isFloat = flags & kAudioFormatFlagIsFloat != 0
        let isSignedInteger = flags & kAudioFormatFlagIsSignedInteger != 0
        guard device.sampleRate <= 192_000,
              device.format.mFormatID == kAudioFormatLinearPCM,
              device.format.mBitsPerChannel == 32 && isFloat ||
                (device.format.mBitsPerChannel == 16 || device.format.mBitsPerChannel == 32) && isSignedInteger else {
            throw AudioDeviceError.unsupportedFormat
        }

        let input = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(CamMicFrameCodec.sampleRate),
            channels: 1,
            interleaved: false
        )!
        let output = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: device.sampleRate,
            channels: 1,
            interleaved: false
        )!
        guard let converter = AVAudioConverter(from: input, to: output) else {
            throw AudioDeviceError.conversionFailed
        }
        inputFormat = input
        outputFormat = output
        self.converter = converter
        slots = (0..<capacity).map { _ in Slot(capacity: slotSampleCapacity) }
    }

    public func start() throws {
        guard !started else { return }
        let queue = DispatchQueue(label: "com.yykx682436.CamMic.coreaudio-device")
        var created: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(&created, device.id, queue) { [weak self] _, _, _, outputData, _ in
            self?.render(outputData)
        }
        guard createStatus == noErr, let created = created else { throw AudioDeviceError.coreAudio(createStatus) }
        ioProcID = created
        let startStatus = AudioDeviceStart(device.id, created)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(device.id, created)
            ioProcID = nil
            throw AudioDeviceError.coreAudio(startStatus)
        }
        started = true
    }

    public func stopAndClear() {
        enqueueLock.lock()
        defer { enqueueLock.unlock() }
        if let ioProcID = ioProcID {
            AudioDeviceStop(device.id, ioProcID)
            AudioDeviceDestroyIOProcID(device.id, ioProcID)
            self.ioProcID = nil
        }
        started = false
        os_unfair_lock_lock(&renderLock)
        head = 0
        tail = 0
        count = 0
        offset = 0
        queuedFrames = 0
        lastConsumed = 0
        playbackActive = false
        driftCorrection = 0
        os_unfair_lock_unlock(&renderLock)
    }

    deinit { stopAndClear() }

    public func enqueue(pcm16LittleEndian: Data, sequence: UInt64) throws {
        enqueueLock.lock()
        defer { enqueueLock.unlock() }
        guard pcm16LittleEndian.count == CamMicFrameCodec.audioPayloadLength,
              let inputFormat = inputFormat, let outputFormat = outputFormat,
              let converter = converter,
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(CamMicFrameCodec.samplesPerFrame)),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096),
              let inputSamples = input.int16ChannelData?.pointee,
              let outputSamples = output.floatChannelData?.pointee else {
            throw AudioDeviceError.conversionFailed
        }
        input.frameLength = AVAudioFrameCount(CamMicFrameCodec.samplesPerFrame)
        for index in 0..<Int(CamMicFrameCodec.samplesPerFrame) {
            let low = UInt16(pcm16LittleEndian[index * 2])
            let high = UInt16(pcm16LittleEndian[index * 2 + 1]) << 8
            inputSamples[index] = Int16(bitPattern: low | high)
        }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard !supplied else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0 else { throw conversionError ?? AudioDeviceError.conversionFailed }

        let sampleCount = Int(output.frameLength)
        guard sampleCount > 0,
              sampleCount + 1 <= slotSampleCapacity else { throw AudioDeviceError.conversionFailed }
        var correctedCount = sampleCount
        os_unfair_lock_lock(&renderLock)
        guard count < capacity else {
            os_unfair_lock_unlock(&renderLock)
            throw AudioDeviceError.queueFull
        }
        let reservedIndex = tail
        let queueDepth = queuedFrames
        let targetDepth = max(1, Int(outputFormat.sampleRate * 0.08))
        let requestedCorrection = Double(queueDepth - targetDepth) / Double(targetDepth) * 0.2
        driftCorrection += max(-0.10, min(0.10, requestedCorrection))
        var removeAt: Int?
        var insertAt: Int?
        if driftCorrection >= 1 {
            removeAt = sampleCount / 2
            driftCorrection -= 1
        } else if driftCorrection <= -1 {
            insertAt = sampleCount / 2
            driftCorrection += 1
        }
        os_unfair_lock_unlock(&renderLock)

        // The producer owns this reserved, not-yet-visible slot. Convert/copy and
        // any buffer mutation stay outside the lock used by the CoreAudio callback.
        let slot = slots[reservedIndex]
        if let removeAt = removeAt {
            correctedCount -= 1
            for index in removeAt..<correctedCount { slot.samples[index] = outputSamples[index + 1] }
            for index in 0..<removeAt { slot.samples[index] = outputSamples[index] }
        } else if let insertAt = insertAt, sampleCount < slot.capacity {
            correctedCount += 1
            for index in 0..<insertAt { slot.samples[index] = outputSamples[index] }
            slot.samples[insertAt] = (outputSamples[max(0, insertAt - 1)] + outputSamples[insertAt]) * 0.5
            for index in insertAt..<sampleCount { slot.samples[index + 1] = outputSamples[index] }
        } else {
            for index in 0..<sampleCount { slot.samples[index] = outputSamples[index] }
        }
        slot.frameCount = correctedCount
        slot.sequence = sequence

        os_unfair_lock_lock(&renderLock)
        tail = (reservedIndex + 1) % capacity
        count += 1
        queuedFrames += correctedCount
        os_unfair_lock_unlock(&renderLock)
    }

    public func markPlaybackActive() {
        os_unfair_lock_lock(&renderLock)
        playbackActive = true
        os_unfair_lock_unlock(&renderLock)
    }

    public var metrics: (
        queuedFrames: Int,
        queuedPackets: Int,
        lastConsumed: UInt64,
        underruns: UInt64,
        renderContentions: UInt64
    ) {
        os_unfair_lock_lock(&renderLock)
        defer { os_unfair_lock_unlock(&renderLock) }
        return (
            queuedFrames,
            count,
            lastConsumed,
            underruns,
            UInt64(max(0, OSAtomicAdd64Barrier(0, &renderContentionCallbacks)))
        )
    }

    private func render(_ outputData: UnsafeMutablePointer<AudioBufferList>?) {
        guard let outputData = outputData else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(outputData)
        let channels = buffers.reduce(UInt32(0)) { $0 + $1.mNumberChannels }
        guard channels >= 2 else {
            for index in buffers.indices {
                if let data = buffers[index].mData { memset(data, 0, Int(buffers[index].mDataByteSize)) }
            }
            return
        }
        for index in buffers.indices {
            if let data = buffers[index].mData { memset(data, 0, Int(buffers[index].mDataByteSize)) }
        }
        let bytesPerSample = Int(device.format.mBitsPerChannel / 8)
        var totalFrames = Int.max
        for index in buffers.indices {
            let buffer = buffers[index]
            totalFrames = min(
                totalFrames,
                Int(buffer.mDataByteSize) / max(1, Int(buffer.mNumberChannels) * bytesPerSample)
            )
        }
        if totalFrames == Int.max { totalFrames = 0 }
        var hadUnderrun = false

        guard os_unfair_lock_trylock(&renderLock) else {
            OSAtomicIncrement64Barrier(&renderContentionCallbacks)
            return
        }
        defer { os_unfair_lock_unlock(&renderLock) }
        for frame in 0..<totalFrames {
            guard count > 0 else { hadUnderrun = true; continue }
            let sample = slots[head].samples[offset]
            write(sample, frame: frame, to: buffers, bytesPerSample: bytesPerSample)
            offset += 1
            queuedFrames -= 1
            if offset == slots[head].frameCount {
                lastConsumed = slots[head].sequence
                slots[head].frameCount = 0
                head = (head + 1) % capacity
                count -= 1
                offset = 0
            }
        }
        if hadUnderrun && playbackActive { underruns += 1 }
    }

    private func write(
        _ sample: Float,
        frame: Int,
        to buffers: UnsafeMutableAudioBufferListPointer,
        bytesPerSample: Int
    ) {
        var channelOffset: UInt32 = 0
        for bufferIndex in buffers.indices {
            let buffer = buffers[bufferIndex]
            guard let base = buffer.mData else { channelOffset += buffer.mNumberChannels; continue }
            for localChannel in 0..<buffer.mNumberChannels {
                let channel = channelOffset + localChannel
                let value: Float = channel < 2 ? sample : 0
                let sampleIndex = frame * Int(buffer.mNumberChannels) + Int(localChannel)
                let pointer = base.advanced(by: sampleIndex * bytesPerSample)
                if device.format.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
                    pointer.storeBytes(of: value, as: Float.self)
                } else if bytesPerSample == 2 {
                    pointer.storeBytes(of: Int16(max(-1, min(1, value)) * 32767), as: Int16.self)
                } else {
                    let scaled = Int32((Double(max(-1, min(1, value))) * 2_147_483_647.0).rounded())
                    pointer.storeBytes(of: scaled, as: Int32.self)
                }
            }
            channelOffset += buffer.mNumberChannels
        }
    }

#if DEBUG
    func renderForTesting(frameCount: Int) -> [Float] {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: device.sampleRate,
            channels: 2,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        render(buffer.mutableAudioBufferList)
        guard let channels = buffer.floatChannelData else { return [] }
        var samples: [Float] = []
        samples.reserveCapacity(frameCount * 2)
        for frame in 0..<frameCount {
            samples.append(channels[0][frame])
            samples.append(channels[1][frame])
        }
        return samples
    }

    func holdRenderLockForTesting(
        acquired: DispatchSemaphore,
        release: DispatchSemaphore,
        finished: DispatchSemaphore
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            os_unfair_lock_lock(&self.renderLock)
            acquired.signal()
            release.wait()
            os_unfair_lock_unlock(&self.renderLock)
            finished.signal()
        }
    }
#endif
}
