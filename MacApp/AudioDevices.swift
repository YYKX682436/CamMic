import AVFoundation
import CamMicShared
import CoreAudio
import Foundation
import os.lock

struct AudioOutputDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let sampleRate: Double
    let channelCount: UInt32
    let format: AudioStreamBasicDescription

    var displayName: String { "\(name) · \(Int(sampleRate)) Hz · \(channelCount) ch" }
}

enum AudioDeviceError: LocalizedError {
    case deviceList(OSStatus)
    case noOutputDevices
    case missingDevice
    case noStereoOutput
    case unsupportedFormat
    case coreAudio(OSStatus)
    case conversionFailed
    case queueFull

    var errorDescription: String? {
        switch self {
        case .deviceList(let status): return "无法读取系统音频设备（CoreAudio \(status)）。"
        case .noOutputDevices: return "没有可用的双声道输出设备。"
        case .missingDevice: return "所选输出设备已不存在。"
        case .noStereoOutput: return "所选设备没有至少两个输出声道。"
        case .unsupportedFormat: return "所选设备的输出格式暂不受支持；请使用 BlackHole 2ch 的默认格式。"
        case .coreAudio(let status): return "无法启动所选音频设备（CoreAudio \(status)）。"
        case .conversionFailed: return "无法将接收的 PCM 转换为所选输出设备格式。"
        case .queueFull: return "Mac 播放缓冲已满，连接将重置以清除积压音频。"
        }
    }
}

enum AudioDeviceCatalog {
    static func outputs() throws -> [AudioOutputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var status = AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size)
        guard status == noErr else { throw AudioDeviceError.deviceList(status) }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &ids)
        guard status == noErr else { throw AudioDeviceError.deviceList(status) }

        let devices = ids.compactMap { outputDevice(id: $0) }
        guard !devices.isEmpty else { throw AudioDeviceError.noOutputDevices }
        return devices.sorted {
            if $0.name.localizedCaseInsensitiveContains("BlackHole 2ch") !=
                $1.name.localizedCaseInsensitiveContains("BlackHole 2ch") {
                return $0.name.localizedCaseInsensitiveContains("BlackHole 2ch")
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func device(uid: String) -> AudioOutputDevice? {
        (try? outputs())?.first(where: { $0.uid == uid })
    }

    private static func outputDevice(id: AudioDeviceID) -> AudioOutputDevice? {
        let channels = channelCount(id: id)
        guard channels >= 2,
              let uid = stringProperty(id: id, selector: kAudioDevicePropertyDeviceUID),
              let name = stringProperty(id: id, selector: kAudioObjectPropertyName),
              let format = streamFormat(id: id),
              format.mSampleRate > 0 else { return nil }
        return AudioOutputDevice(
            id: id,
            uid: uid,
            name: name,
            sampleRate: format.mSampleRate,
            channelCount: channels,
            format: format
        )
    }

    private static func stringProperty(id: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeUnretainedValue() as String?
    }

    private static func streamFormat(id: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func channelCount(id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        let list = storage.assumingMemoryBound(to: AudioBufferList.self)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, list) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + $1.mNumberChannels }
    }
}

/// Direct CoreAudio output to the chosen device UID. Its callback only drains a fixed ring and writes silence on underrun.
final class AudioDeviceOutput {
    private struct Slot {
        var samples = [Float](repeating: 0, count: 4096)
        var frameCount = 0
        var sequence: UInt64 = 0
    }

    let device: AudioOutputDevice
    private let capacity = 12
    private var slots: [Slot] = []
    private var head = 0
    private var tail = 0
    private var count = 0
    private var offset = 0
    private var queuedFrames = 0
    private var lastConsumed: UInt64 = 0
    private var underruns: UInt64 = 0
    private var renderLock = os_unfair_lock_s()
    private var ioProcID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var driftCorrection = 0.0
    private var started = false
    private var playbackActive = false

    init(device: AudioOutputDevice) throws {
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
        slots = (0..<capacity).map { _ in Slot() }
    }

    func start() throws {
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

    func stopAndClear() {
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

    func enqueue(pcm16LittleEndian: Data, sequence: UInt64) throws {
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
        var correctedCount = sampleCount
        var queueDepth: Int
        os_unfair_lock_lock(&renderLock)
        queueDepth = queuedFrames
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
        guard count < capacity else {
            os_unfair_lock_unlock(&renderLock)
            throw AudioDeviceError.queueFull
        }
        var slot = slots[tail]
        if let removeAt = removeAt {
            correctedCount -= 1
            for index in removeAt..<correctedCount { slot.samples[index] = outputSamples[index + 1] }
            for index in 0..<removeAt { slot.samples[index] = outputSamples[index] }
        } else if let insertAt = insertAt, sampleCount < slot.samples.count {
            correctedCount += 1
            for index in 0..<insertAt { slot.samples[index] = outputSamples[index] }
            slot.samples[insertAt] = (outputSamples[max(0, insertAt - 1)] + outputSamples[insertAt]) * 0.5
            for index in insertAt..<sampleCount { slot.samples[index + 1] = outputSamples[index] }
        } else {
            for index in 0..<sampleCount { slot.samples[index] = outputSamples[index] }
        }
        slot.frameCount = correctedCount
        slot.sequence = sequence
        slots[tail] = slot
        tail = (tail + 1) % capacity
        count += 1
        queuedFrames += correctedCount
        os_unfair_lock_unlock(&renderLock)
    }

    func markPlaybackActive() {
        os_unfair_lock_lock(&renderLock)
        playbackActive = true
        os_unfair_lock_unlock(&renderLock)
    }

    var metrics: (queuedFrames: Int, queuedPackets: Int, lastConsumed: UInt64, underruns: UInt64) {
        os_unfair_lock_lock(&renderLock)
        defer { os_unfair_lock_unlock(&renderLock) }
        return (queuedFrames, count, lastConsumed, underruns)
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
        let totalFrames = buffers.map { Int($0.mDataByteSize) / max(1, Int($0.mNumberChannels) * bytesPerSample) }.min() ?? 0
        var hadUnderrun = false

        os_unfair_lock_lock(&renderLock)
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
        os_unfair_lock_unlock(&renderLock)
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
}
