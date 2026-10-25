import AVFoundation
import CoreAudio
import XCTest
@testable import CamMicMacCore

final class AudioDeviceCatalogTests: XCTestCase {
    func testHiddenOutputUIDResolvesDirectlyAndReadsOnlyOutputScope() throws {
        let reader = StubAudioDeviceProperties(uid: "CamMic2ch_2_UID", id: 42, inputChannels: 0, outputChannels: 2)

        let device = try XCTUnwrap(AudioDeviceCatalog.device(uid: "CamMic2ch_2_UID", using: reader))

        XCTAssertEqual(reader.translatedUIDs, ["CamMic2ch_2_UID"])
        XCTAssertEqual(device.id, 42)
        XCTAssertEqual(device.name, "CamMicInternalOutput")
        XCTAssertEqual(device.channelCount, 2)
        XCTAssertEqual(reader.channelScopes, [kAudioDevicePropertyScopeOutput])
        XCTAssertEqual(reader.formatScopes, [kAudioDevicePropertyScopeOutput])
        XCTAssertEqual(reader.nameScopes, [kAudioObjectPropertyScopeGlobal])
        XCTAssertEqual(reader.hiddenChecks, [1])
    }

    func testPublicMicrophoneUIDIsResolvedIndependentlyInInputScope() throws {
        let reader = StubAudioDeviceProperties(uid: "CamMic2ch_UID", id: 41, inputChannels: 2, outputChannels: 0)

        let microphone = try XCTUnwrap(AudioDeviceCatalog.input(uid: "CamMic2ch_UID", using: reader))

        XCTAssertEqual(reader.translatedUIDs, ["CamMic2ch_UID"])
        XCTAssertEqual(microphone.id, 41)
        XCTAssertEqual(microphone.name, "CamMic")
        XCTAssertEqual(microphone.channelCount, 2)
        XCTAssertEqual(reader.channelScopes, [kAudioDevicePropertyScopeInput])
        XCTAssertEqual(reader.formatScopes, [kAudioDevicePropertyScopeInput])
        XCTAssertEqual(reader.hiddenChecks, [0])
    }

    func testOutputLookupRejectsInputOnlyDeviceAndDoesNotEnumerateDevices() {
        let reader = StubAudioDeviceProperties(uid: "CamMic2ch_UID", id: 41, inputChannels: 2, outputChannels: 0)

        XCTAssertNil(AudioDeviceCatalog.device(uid: "CamMic2ch_UID", using: reader))
        XCTAssertEqual(reader.translatedUIDs, ["CamMic2ch_UID"])
        XCTAssertEqual(reader.channelScopes, [kAudioDevicePropertyScopeOutput])
        XCTAssertTrue(reader.formatScopes.isEmpty)
    }

    func testInputLookupRejectsOutputOnlyDevice() {
        let reader = StubAudioDeviceProperties(uid: "CamMic2ch_2_UID", id: 42, inputChannels: 0, outputChannels: 2)

        XCTAssertNil(AudioDeviceCatalog.input(uid: "CamMic2ch_2_UID", using: reader))
        XCTAssertEqual(reader.channelScopes, [kAudioDevicePropertyScopeInput])
        XCTAssertTrue(reader.formatScopes.isEmpty)
    }

    func testOutputLookupRequiresTheHiddenCamMicEndpointAndStableName() {
        let visibleOutput = StubAudioDeviceProperties(
            uid: "CamMic2ch_2_UID", id: 42, inputChannels: 0, outputChannels: 2, hidden: false
        )
        XCTAssertNil(AudioDeviceCatalog.device(uid: "CamMic2ch_2_UID", using: visibleOutput))

        let renamedOutput = StubAudioDeviceProperties(
            uid: "CamMic2ch_2_UID", id: 42, inputChannels: 0, outputChannels: 2, name: "CamMic", hidden: true
        )
        let original = AudioOutputDevice(
            id: 42, uid: "CamMic2ch_2_UID", name: "CamMicInternalOutput", sampleRate: 48_000,
            channelCount: 2, format: renamedOutput.streamFormat(id: 42, scope: kAudioDevicePropertyScopeOutput)!
        )
        XCTAssertFalse(AudioDeviceCatalog.isCurrentOutput(original, using: renamedOutput))
    }

    func testPublicMicrophoneMustRemainVisible() {
        let hiddenInput = StubAudioDeviceProperties(
            uid: "CamMic2ch_UID", id: 41, inputChannels: 2, outputChannels: 0, hidden: true
        )
        XCTAssertNil(AudioDeviceCatalog.input(uid: "CamMic2ch_UID", using: hiddenInput))
    }

    func testDeviceLossReplacementAndDirectionChangeInvalidateTheRunningOutput() throws {
        let originalReader = StubAudioDeviceProperties(uid: "CamMic2ch_2_UID", id: 42, inputChannels: 0, outputChannels: 2)
        let original = try XCTUnwrap(AudioDeviceCatalog.device(uid: "CamMic2ch_2_UID", using: originalReader))
        XCTAssertTrue(AudioDeviceCatalog.isCurrentOutput(original, using: originalReader))

        let missing = StubAudioDeviceProperties(uid: "CamMic2ch_2_UID", id: nil, inputChannels: 0, outputChannels: 0)
        XCTAssertFalse(AudioDeviceCatalog.isCurrentOutput(original, using: missing))

        let replacement = StubAudioDeviceProperties(uid: "CamMic2ch_2_UID", id: 99, inputChannels: 0, outputChannels: 2)
        XCTAssertFalse(AudioDeviceCatalog.isCurrentOutput(original, using: replacement), "A new CoreAudio handle must end the old output session")

        let changedFormat = StubAudioDeviceProperties(uid: "CamMic2ch_2_UID", id: 42, inputChannels: 0, outputChannels: 2, sampleRate: 44_100)
        XCTAssertFalse(AudioDeviceCatalog.isCurrentOutput(original, using: changedFormat), "A changed output format must end the old session")

        let changedDirection = StubAudioDeviceProperties(uid: "CamMic2ch_2_UID", id: 42, inputChannels: 2, outputChannels: 0)
        XCTAssertFalse(AudioDeviceCatalog.isCurrentOutput(original, using: changedDirection))
    }

    func testDeviceLossReplacementAndDirectionChangeInvalidateTheRunningInput() throws {
        let originalReader = StubAudioDeviceProperties(uid: "CamMic2ch_UID", id: 41, inputChannels: 2, outputChannels: 0)
        let original = try XCTUnwrap(AudioDeviceCatalog.input(uid: "CamMic2ch_UID", using: originalReader))
        XCTAssertTrue(AudioDeviceCatalog.isCurrentInput(original, using: originalReader))

        let missing = StubAudioDeviceProperties(uid: "CamMic2ch_UID", id: nil, inputChannels: 0, outputChannels: 0)
        XCTAssertFalse(AudioDeviceCatalog.isCurrentInput(original, using: missing))

        let replacement = StubAudioDeviceProperties(uid: "CamMic2ch_UID", id: 100, inputChannels: 2, outputChannels: 0)
        XCTAssertFalse(AudioDeviceCatalog.isCurrentInput(original, using: replacement))

        let changedDirection = StubAudioDeviceProperties(uid: "CamMic2ch_UID", id: 41, inputChannels: 0, outputChannels: 2)
        XCTAssertFalse(AudioDeviceCatalog.isCurrentInput(original, using: changedDirection))

        let changedFormat = StubAudioDeviceProperties(uid: "CamMic2ch_UID", id: 41, inputChannels: 2, outputChannels: 0, sampleRate: 44_100)
        XCTAssertFalse(AudioDeviceCatalog.isCurrentInput(original, using: changedFormat), "A changed input format must end the old session")
    }
}

private final class StubAudioDeviceProperties: AudioDevicePropertyReading {
    private let knownUID: String
    private let resolvedID: AudioDeviceID?
    private let inputChannels: UInt32
    private let outputChannels: UInt32
    private let sampleRate: Double
    private let hidden: Bool
    private let deviceName: String?

    private(set) var translatedUIDs: [String] = []
    private(set) var channelScopes: [AudioObjectPropertyScope] = []
    private(set) var formatScopes: [AudioObjectPropertyScope] = []
    private(set) var nameScopes: [AudioObjectPropertyScope] = []
    private(set) var hiddenChecks: [UInt32] = []

    init(uid: String, id: AudioDeviceID?, inputChannels: UInt32, outputChannels: UInt32,
         sampleRate: Double = 48_000, name: String? = nil, hidden: Bool? = nil) {
        knownUID = uid
        resolvedID = id
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
        self.sampleRate = sampleRate
        deviceName = name
        self.hidden = hidden ?? (uid == "CamMic2ch_2_UID")
    }

    func deviceID(forUID uid: String) -> AudioDeviceID? {
        translatedUIDs.append(uid)
        return uid == knownUID ? resolvedID : nil
    }

    func stringProperty(id: AudioDeviceID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> String? {
        nameScopes.append(scope)
        return deviceName ?? (knownUID == "CamMic2ch_UID" ? "CamMic" : "CamMicInternalOutput")
    }

    func uintProperty(id: AudioDeviceID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> UInt32? {
        guard selector == kAudioDevicePropertyIsHidden else { return nil }
        hiddenChecks.append(hidden ? 1 : 0)
        return hidden ? 1 : 0
    }

    func streamFormat(id: AudioDeviceID, scope: AudioObjectPropertyScope) -> AudioStreamBasicDescription? {
        formatScopes.append(scope)
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    func channelCount(id: AudioDeviceID, scope: AudioObjectPropertyScope) -> UInt32 {
        channelScopes.append(scope)
        return scope == kAudioDevicePropertyScopeInput ? inputChannels : outputChannels
    }
}
