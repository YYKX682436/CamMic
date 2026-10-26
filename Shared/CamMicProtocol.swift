import Foundation
import Network
import Security
import Dispatch

public enum CamMicFrameKind: UInt16 {
    case hello = 1
    case ready = 2
    case audio = 3
    case acknowledgement = 4
}

public struct CamMicFrame: Equatable {
    public let kind: CamMicFrameKind
    public let sessionID: Data
    public let sequence: UInt64
    public let payload: Data

    public init(kind: CamMicFrameKind, sessionID: Data, sequence: UInt64 = 0, payload: Data = Data()) {
        self.kind = kind
        self.sessionID = sessionID
        self.sequence = sequence
        self.payload = payload
    }
}

public enum CamMicProtocolError: Error, Equatable {
    case invalidSessionID
    case invalidPayloadLength
    case invalidMagic
    case unsupportedVersion
    case unknownFrameKind
    case bufferLimitExceeded
    case wrongSession
    case invalidSequence
}

/// Version 1 wire framing. All integer fields are big-endian; audio payloads are signed PCM16 LE.
public enum CamMicFrameCodec {
    public static let version: UInt16 = 1
    public static let headerLength = 36
    public static let sampleRate: UInt32 = 48_000
    public static let channelCount: UInt16 = 1
    public static let bitsPerSample: UInt16 = 16
    public static let tcpPort: UInt16 = 50888
    public static let samplesPerFrame: UInt32 = 960
    public static let audioPayloadLength = Int(samplesPerFrame) * Int(bitsPerSample / 8)
    public static let maximumPayloadLength = audioPayloadLength
    public static let maximumBufferedBytes = 64 * 1024

    public static func encode(_ frame: CamMicFrame) throws -> Data {
        guard frame.sessionID.count == 16 else { throw CamMicProtocolError.invalidSessionID }
        guard isValidPayload(frame.kind, frame.payload.count) else { throw CamMicProtocolError.invalidPayloadLength }
        var data = Data(capacity: headerLength + frame.payload.count)
        data.append(contentsOf: [0x43, 0x4D, 0x49, 0x43]) // CMIC
        append(version, to: &data)
        append(frame.kind.rawValue, to: &data)
        data.append(frame.sessionID)
        append(frame.sequence, to: &data)
        append(UInt32(frame.payload.count), to: &data)
        data.append(frame.payload)
        return data
    }

    fileprivate static func isValidPayload(_ kind: CamMicFrameKind, _ count: Int) -> Bool {
        switch kind {
        case .hello: return count == 12
        case .ready, .acknowledgement: return count == 0
        case .audio: return count == audioPayloadLength
        }
    }

    fileprivate static func append(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    fileprivate static func append(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    fileprivate static func append(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }

    fileprivate static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    fileprivate static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16) |
            (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
    }

    fileprivate static func readUInt64(_ data: Data, _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 { value = (value << 8) | UInt64(data[offset + index]) }
        return value
    }
}

/// Incremental bounded decoder for TCP streams. It accepts partial headers/payloads and coalesced frames.
public struct CamMicFrameDecoder {
    private var bytes = Data()

    public init() {}

    public mutating func append(_ incoming: Data) throws -> [CamMicFrame] {
        guard incoming.count <= CamMicFrameCodec.maximumBufferedBytes,
              bytes.count + incoming.count <= CamMicFrameCodec.maximumBufferedBytes else {
            throw CamMicProtocolError.bufferLimitExceeded
        }
        bytes.append(incoming)
        var frames: [CamMicFrame] = []
        while bytes.count >= CamMicFrameCodec.headerLength {
            guard bytes.prefix(4).elementsEqual([0x43, 0x4D, 0x49, 0x43]) else {
                throw CamMicProtocolError.invalidMagic
            }
            guard CamMicFrameCodec.readUInt16(bytes, 4) == CamMicFrameCodec.version else {
                throw CamMicProtocolError.unsupportedVersion
            }
            guard let kind = CamMicFrameKind(rawValue: CamMicFrameCodec.readUInt16(bytes, 6)) else {
                throw CamMicProtocolError.unknownFrameKind
            }
            let payloadLength = Int(CamMicFrameCodec.readUInt32(bytes, 32))
            guard payloadLength <= CamMicFrameCodec.maximumPayloadLength,
                  CamMicFrameCodec.isValidPayload(kind, payloadLength) else {
                throw CamMicProtocolError.invalidPayloadLength
            }
            let totalLength = CamMicFrameCodec.headerLength + payloadLength
            guard bytes.count >= totalLength else { break }
            let frame = CamMicFrame(
                kind: kind,
                sessionID: bytes.subdata(in: 8..<24),
                sequence: CamMicFrameCodec.readUInt64(bytes, 24),
                payload: bytes.subdata(in: CamMicFrameCodec.headerLength..<totalLength)
            )
            frames.append(frame)
            bytes.removeSubrange(0..<totalLength)
        }
        return frames
    }
}

/// Validates per-session ordering independently of any socket implementation.
public struct CamMicReceiveSequence {
    public let sessionID: Data
    public private(set) var lastReceived: UInt64 = 0

    public init(sessionID: Data) throws {
        guard sessionID.count == 16 else { throw CamMicProtocolError.invalidSessionID }
        self.sessionID = sessionID
    }

    public mutating func accept(_ frame: CamMicFrame) throws {
        guard frame.sessionID == sessionID else { throw CamMicProtocolError.wrongSession }
        guard frame.kind == .audio, frame.sequence == lastReceived + 1 else {
            throw CamMicProtocolError.invalidSequence
        }
        lastReceived = frame.sequence
    }
}

/// Thread-safe cumulative ACK window used by the sender. Sequence numbers are
/// reserved only when a packet can be sent immediately.
public final class CamMicAcknowledgementWindow {
    private let lock = NSLock()
    private let maximumInFlight: UInt64
    private var lastAcknowledged: UInt64 = 0
    private var nextSequence: UInt64 = 1
    private var stopped = false

    public init(maximumInFlight: UInt64 = 16) {
        self.maximumInFlight = max(1, maximumInFlight)
    }

    public func tryAcquireNextSequence() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return nil }
        guard nextSequence - 1 - lastAcknowledged < maximumInFlight else { return nil }
        let result = nextSequence
        nextSequence += 1
        return result
    }

    public func acknowledge(_ sequence: UInt64) throws {
        lock.lock()
        defer { lock.unlock() }
        guard sequence > 0, sequence < nextSequence else { throw CamMicProtocolError.invalidSequence }
        if sequence > lastAcknowledged {
            lastAcknowledged = sequence
        }
    }

    public func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    public var inFlightCount: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return nextSequence - 1 - lastAcknowledged
    }
}

/// A fixed-size handoff from PCM conversion to network transmission. When the
/// receiver falls behind, it keeps the newest audio and discards stale packets.
public final class CamMicPendingAudioBuffer {
    public struct Packet: Equatable {
        public let capturedAtNanoseconds: UInt64
        public let payload: Data
    }

    public struct Snapshot: Equatable {
        public let queuedPackets: Int
        public let droppedPackets: UInt64
        public let highWaterMark: Int
    }

    private let lock = NSLock()
    private let maximumPackets: Int
    private var packets: [Packet] = []
    private var droppedPackets: UInt64 = 0
    private var highWaterMark = 0

    public init(maximumPackets: Int) {
        precondition(maximumPackets > 0)
        self.maximumPackets = maximumPackets
        packets.reserveCapacity(maximumPackets)
    }

    /// Returns the number of stale packets removed to make room for this packet.
    @discardableResult
    public func enqueue(capturedAtNanoseconds: UInt64, payload: Data) -> UInt64 {
        precondition(payload.count == CamMicFrameCodec.audioPayloadLength)
        lock.lock()
        var dropped: UInt64 = 0
        if packets.count == maximumPackets {
            packets.removeFirst()
            dropped = 1
            droppedPackets += 1
        }
        packets.append(Packet(capturedAtNanoseconds: capturedAtNanoseconds, payload: payload))
        highWaterMark = max(highWaterMark, packets.count)
        lock.unlock()
        return dropped
    }

    public func dequeue() -> Packet? {
        lock.lock()
        defer { lock.unlock() }
        guard !packets.isEmpty else { return nil }
        return packets.removeFirst()
    }

    /// Clears a disconnected session's old audio and returns the packet count.
    @discardableResult
    public func clear() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let removed = packets.count
        droppedPackets += UInt64(removed)
        packets.removeAll(keepingCapacity: true)
        return removed
    }

    public var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            queuedPackets: packets.count,
            droppedPackets: droppedPackets,
            highWaterMark: highWaterMark
        )
    }
}

public enum CamMicPairing {
    public static let tlsPSKIdentity = Data("CamMic-v1".utf8)
    public static let usbTLSPSKIdentity = Data("CamMic-USB-v1".utf8)
    public static let sessionKeyLength = 32

    public static func newCode() -> String {
        String(format: "%08u", UInt32.random(in: 0...99_999_999))
    }

    public static func newSessionKey() throws -> Data {
        var key = Data(count: sessionKeyLength)
        let status = key.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
        }
        guard status == errSecSuccess else { throw CamMicPairingError.secureRandomUnavailable }
        return key
    }

    public static func makeNetworkParameters(pairingCode: String) -> NWParameters {
        makeNetworkParameters(preSharedKey: Data(pairingCode.utf8), identity: tlsPSKIdentity)
    }

    public static func makeNetworkParameters(preSharedKey: Data, identity: Data) -> NWParameters {
        precondition(!preSharedKey.isEmpty)
        let tls = NWProtocolTLS.Options()
        preSharedKey.withUnsafeBytes { keyBytes in
            identity.withUnsafeBytes { identityBytes in
                sec_protocol_options_add_pre_shared_key(
                    tls.securityProtocolOptions,
                    DispatchData(bytes: keyBytes) as __DispatchData,
                    DispatchData(bytes: identityBytes) as __DispatchData
                )
            }
        }
        // Network.framework's PSK API is limited to TLS 1.2.
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        return NWParameters(tls: tls, tcp: tcp)
    }
}

public enum CamMicPairingError: Error {
    case secureRandomUnavailable
}

/// Framing for the Debug-only USB probe's unauthenticated, loopback init channel.
/// USBMux's device trust controls access to the forwarded socket; this framing does
/// not authenticate a particular Mac application or public key.
public enum CamMicUSBSessionMaterialCodec {
    public static let keyLength = CamMicPairing.sessionKeyLength
    public static let request = Data([0x43, 0x4D, 0x49, 0x51, 0x00, 0x01]) // CMIQ, v1
    public static let responseLength = 4 + 2 + keyLength

    public static func encodeResponse(sessionKey: Data) throws -> Data {
        guard sessionKey.count == keyLength else { throw CamMicProtocolError.invalidPayloadLength }
        var response = Data([0x43, 0x4D, 0x55, 0x49]) // CMUI
        response.append(0x00)
        response.append(0x01)
        response.append(sessionKey)
        return response
    }

    public static func decodeRequest(_ data: Data) -> Bool {
        data == request
    }

    public static func decodeResponse(_ data: Data) throws -> Data {
        guard data.count == responseLength,
              data.prefix(4).elementsEqual([0x43, 0x4D, 0x55, 0x49]) else {
            throw CamMicProtocolError.invalidMagic
        }
        guard data[4] == 0, data[5] == 1 else { throw CamMicProtocolError.unsupportedVersion }
        return data.subdata(in: 6..<responseLength)
    }
}
