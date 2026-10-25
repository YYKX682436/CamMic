import CamMicMacCore

enum CamMicAudioDeviceIdentity {
    static let publicInputName = "CamMic"
    static let hiddenOutputName = "CamMicInternalOutput"
    static let publicInputUID = "CamMic2ch_UID"
    static let hiddenOutputUID = "CamMic2ch_2_UID"
    static let modelUID = "CamMic2ch_ModelUID"
    static let plugInBundleID = "com.yykx682436.CamMicAudioDriver"
    static let plugInFactoryUUID = "4b469f5a-1284-4ac8-b82c-75026d5ae711"
}

struct CamMicAudioEndpoints {
    let microphone: AudioInputDevice
    let appOutput: AudioOutputDevice
}

enum CamMicAudioDevices {
    static func current() -> CamMicAudioEndpoints? {
        guard let microphone = AudioDeviceCatalog.input(uid: CamMicAudioDeviceIdentity.publicInputUID),
              microphone.name == CamMicAudioDeviceIdentity.publicInputName,
              let appOutput = AudioDeviceCatalog.device(uid: CamMicAudioDeviceIdentity.hiddenOutputUID),
              appOutput.name == CamMicAudioDeviceIdentity.hiddenOutputName else { return nil }
        return CamMicAudioEndpoints(microphone: microphone, appOutput: appOutput)
    }
}
