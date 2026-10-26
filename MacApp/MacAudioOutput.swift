import CamMicMacCore
import Foundation

protocol MacAudioOutputControlling: AnyObject {
    var metrics: (
        queuedFrames: Int,
        queuedPackets: Int,
        lastConsumed: UInt64,
        underruns: UInt64,
        renderContentions: UInt64
    ) { get }

    func start() throws
    func stopAndClear()
    func setMuted(_ muted: Bool)
    func enqueue(pcm16LittleEndian: Data, sequence: UInt64) throws
    func markPlaybackActive()
}

extension AudioDeviceOutput: MacAudioOutputControlling {}
