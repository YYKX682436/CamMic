import CamMicMacCore
import CoreAudio
import Foundation

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
        guard let value = value else { return nil }
        return value.takeRetainedValue() as String
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
