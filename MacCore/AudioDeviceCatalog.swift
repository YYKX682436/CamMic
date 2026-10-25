import CoreAudio
import CoreFoundation
import Foundation

public struct AudioInputDevice {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let channelCount: UInt32
    public let format: AudioStreamBasicDescription

    public init(
        id: AudioDeviceID,
        uid: String,
        name: String,
        channelCount: UInt32,
        format: AudioStreamBasicDescription
    ) {
        self.id = id
        self.uid = uid
        self.name = name
        self.channelCount = channelCount
        self.format = format
    }
}

protocol AudioDevicePropertyReading {
    func deviceID(forUID uid: String) -> AudioDeviceID?
    func stringProperty(id: AudioDeviceID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> String?
    func uintProperty(id: AudioDeviceID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> UInt32?
    func streamFormat(id: AudioDeviceID, scope: AudioObjectPropertyScope) -> AudioStreamBasicDescription?
    func channelCount(id: AudioDeviceID, scope: AudioObjectPropertyScope) -> UInt32
}

/// Resolves persistent device UIDs through CoreAudio and checks the requested direction's scope.
/// This intentionally does not enumerate `kAudioHardwarePropertyDevices`: hidden devices are
/// addressable by UID even though the system omits them from ordinary output-device lists.
public enum AudioDeviceCatalog {
    public static func device(uid: String) -> AudioOutputDevice? {
        device(uid: uid, using: CoreAudioDevicePropertyReader())
    }

    public static func input(uid: String) -> AudioInputDevice? {
        input(uid: uid, using: CoreAudioDevicePropertyReader())
    }

    public static func isCurrentOutput(_ expected: AudioOutputDevice) -> Bool {
        isCurrentOutput(expected, using: CoreAudioDevicePropertyReader())
    }

    public static func isCurrentInput(_ expected: AudioInputDevice) -> Bool {
        isCurrentInput(expected, using: CoreAudioDevicePropertyReader())
    }

    static func device(uid: String, using reader: AudioDevicePropertyReading) -> AudioOutputDevice? {
        guard let id = reader.deviceID(forUID: uid),
              id != kAudioObjectUnknown,
              let channelCount = outputChannelCount(id: id, using: reader),
              reader.uintProperty(id: id, selector: kAudioDevicePropertyIsHidden, scope: kAudioObjectPropertyScopeGlobal) == 1,
              let name = reader.stringProperty(id: id, selector: kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal),
              let format = reader.streamFormat(id: id, scope: kAudioDevicePropertyScopeOutput),
              format.mSampleRate > 0 else { return nil }

        return AudioOutputDevice(
            id: id,
            uid: uid,
            name: name,
            sampleRate: format.mSampleRate,
            channelCount: channelCount,
            format: format
        )
    }

    static func input(uid: String, using reader: AudioDevicePropertyReading) -> AudioInputDevice? {
        guard let id = reader.deviceID(forUID: uid),
              id != kAudioObjectUnknown,
              let channelCount = inputChannelCount(id: id, using: reader),
              reader.uintProperty(id: id, selector: kAudioDevicePropertyIsHidden, scope: kAudioObjectPropertyScopeGlobal) == 0,
              let name = reader.stringProperty(id: id, selector: kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal),
              let format = reader.streamFormat(id: id, scope: kAudioDevicePropertyScopeInput),
              format.mSampleRate > 0 else {
            return nil
        }

        return AudioInputDevice(
            id: id,
            uid: uid,
            name: name,
            channelCount: channelCount,
            format: format
        )
    }

    static func isCurrentOutput(_ expected: AudioOutputDevice, using reader: AudioDevicePropertyReading) -> Bool {
        guard let current = device(uid: expected.uid, using: reader), current.id == expected.id else { return false }
        return current.name == expected.name && current.channelCount == expected.channelCount &&
            hasSameFormat(current.format, expected.format)
    }

    static func isCurrentInput(_ expected: AudioInputDevice, using reader: AudioDevicePropertyReading) -> Bool {
        guard let current = input(uid: expected.uid, using: reader) else { return false }
        return current.id == expected.id && current.name == expected.name &&
            current.channelCount == expected.channelCount && hasSameFormat(current.format, expected.format)
    }

    private static func hasSameFormat(
        _ current: AudioStreamBasicDescription,
        _ expected: AudioStreamBasicDescription
    ) -> Bool {
        current.mSampleRate == expected.mSampleRate &&
            current.mFormatID == expected.mFormatID &&
            current.mFormatFlags == expected.mFormatFlags &&
            current.mBytesPerPacket == expected.mBytesPerPacket &&
            current.mFramesPerPacket == expected.mFramesPerPacket &&
            current.mBytesPerFrame == expected.mBytesPerFrame &&
            current.mChannelsPerFrame == expected.mChannelsPerFrame &&
            current.mBitsPerChannel == expected.mBitsPerChannel
    }

    private static func outputChannelCount(id: AudioDeviceID, using reader: AudioDevicePropertyReading) -> UInt32? {
        let count = reader.channelCount(id: id, scope: kAudioDevicePropertyScopeOutput)
        return count >= 2 ? count : nil
    }

    private static func inputChannelCount(id: AudioDeviceID, using reader: AudioDevicePropertyReading) -> UInt32? {
        let count = reader.channelCount(id: id, scope: kAudioDevicePropertyScopeInput)
        return count > 0 ? count : nil
    }
}

private struct CoreAudioDevicePropertyReader: AudioDevicePropertyReading {
    private let systemObject = AudioObjectID(kAudioObjectSystemObject)

    func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifier = uid as CFString
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        let qualifierSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafePointer(to: &qualifier) { pointer in
            AudioObjectGetPropertyData(
                systemObject,
                &address,
                qualifierSize,
                UnsafeRawPointer(pointer),
                &size,
                &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    func stringProperty(
        id: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let value = value else { return nil }
        return value.takeRetainedValue() as String
    }

    func streamFormat(id: AudioDeviceID, scope: AudioObjectPropertyScope) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    func uintProperty(id: AudioDeviceID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    func channelCount(id: AudioDeviceID, scope: AudioObjectPropertyScope) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
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
