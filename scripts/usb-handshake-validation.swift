import Foundation
import Network
import Security
import Darwin

// Client-only physical-device validator. Keys stay in memory and are never
// printed, hashed, written to disk, or passed as command-line arguments.
private struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw ProbeFailure(description: message) }
}

private func fetchSessionKey() throws -> Data {
    let queue = DispatchQueue(label: "CamMic.usb-validation.init")
    let finished = DispatchSemaphore(value: 0)
    let connection = NWConnection(host: .ipv4(.loopback), port: 50889, using: .tcp)
    let request = try CamMicUSBSessionMaterialCodec.makeRequest()
    var response = Data()
    var result: Result<Data, ProbeFailure>?
    func finish(_ value: Result<Data, ProbeFailure>) {
        guard result == nil else { return }
        result = value
        finished.signal()
    }
    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: CamMicUSBSessionMaterialCodec.responseLength) { bytes, _, complete, error in
            guard result == nil else { return }
            if let bytes = bytes { response.append(bytes) }
            guard response.count <= CamMicUSBSessionMaterialCodec.responseLength else {
                finish(.failure(ProbeFailure(description: "init response exceeded its bound")))
                return
            }
            if response.count == CamMicUSBSessionMaterialCodec.responseLength {
                do { finish(.success(try CamMicUSBSessionMaterialCodec.decodeResponse(response, expectedNonce: request.nonce))) }
                catch { finish(.failure(ProbeFailure(description: "invalid init response"))) }
            } else if error != nil || complete {
                finish(.failure(ProbeFailure(description: "init channel closed before a valid response")))
            } else { receive() }
        }
    }
    connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
            connection.send(content: request.message, completion: .contentProcessed { error in
                if error != nil { finish(.failure(ProbeFailure(description: "init request failed"))) }
                else { receive() }
            })
        case .failed:
            finish(.failure(ProbeFailure(description: "init transport failed")))
        default: break
        }
    }
    connection.start(queue: queue)
    _ = finished.wait(timeout: .now() + 4)
    return try queue.sync {
        connection.stateUpdateHandler = nil
        connection.cancel()
        defer { response.resetBytes(in: 0..<response.count) }
        return try result?.get() ?? { throw ProbeFailure(description: "init deadline exceeded") }()
    }
}

private final class AudioProbe {
    struct Snapshot {
        let packets: UInt64
        let bytes: UInt64
        let rms: Double
        let peak: Double
        let failure: String?
        let session: Data?
        let cipher: UInt16?
        let state: String
    }
    private let queue = DispatchQueue(label: "CamMic.usb-validation.audio")
    private let firstResult = DispatchSemaphore(value: 0)
    private let connection: NWConnection
    private var decoder = CamMicFrameDecoder()
    private var sequence: CamMicReceiveSequence?
    private var packets: UInt64 = 0
    private var bytes: UInt64 = 0
    private var sumSquares = 0.0
    private var peak = 0.0
    private var failure: String?
    private var cipher: UInt16?
    private var signaled = false
    private var active = true
    private var lastState = "not started"

    init(key: Data, identity: Data = CamMicPairing.usbTLSPSKIdentity) {
        connection = NWConnection(host: .ipv4(.loopback), port: 50890,
                                  using: CamMicPairing.makeNetworkParameters(preSharedKey: key, identity: identity))
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self, self.active else { return }
            self.lastState = String(describing: state)
            switch state {
            case .ready:
                let metadata = self.connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata
                self.cipher = metadata.map { sec_protocol_metadata_get_negotiated_tls_ciphersuite($0.securityProtocolMetadata).rawValue }
                let pskSuites: Set<UInt16> = [0x002C, 0x008A, 0x008B, 0x008C, 0x008D, 0x00A8, 0x00A9, 0x00AE, 0x00AF, 0x00B0, 0x00B1, 0xCCAB]
                guard let cipher = self.cipher, pskSuites.contains(cipher) else {
                    self.fail("non-PSK cipher negotiated")
                    return
                }
                self.receive()
            case .failed(let error): self.fail("transport/TLS rejected: \(error)")
            case .waiting(let error): self.fail("transport/TLS waiting: \(error)")
            case .cancelled: self.fail("connection cancelled")
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func signalOnce() {
        guard !signaled else { return }
        signaled = true
        firstResult.signal()
    }

    private func fail(_ message: String) {
        guard active, failure == nil else { return }
        failure = message
        signalOnce()
        connection.cancel()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
            guard let self = self, self.active, self.failure == nil else { return }
            do {
                if let data = data {
                    for frame in try self.decoder.append(data) { try self.consume(frame) }
                }
                if error != nil || complete { self.fail("audio channel closed") }
                else { self.receive() }
            } catch { self.fail("HELLO/session/sequence validation failed") }
        }
    }

    private func consume(_ frame: CamMicFrame) throws {
        if frame.kind == .hello {
            // v1: 48000 Hz, mono, PCM16, 960 samples/frame. Shared codec owns framing.
            let format = Data([0, 0, 0xBB, 0x80, 0, 1, 0, 16, 0, 0, 3, 0xC0])
            try require(sequence == nil && frame.sequence == 0 && frame.payload == format, "unexpected HELLO")
            sequence = try CamMicReceiveSequence(sessionID: frame.sessionID)
            send(CamMicFrame(kind: .ready, sessionID: frame.sessionID))
        } else {
            guard var sequence = sequence else { throw ProbeFailure(description: "audio before HELLO") }
            try sequence.accept(frame)
            self.sequence = sequence
            packets += 1
            bytes += UInt64(frame.payload.count)
            for index in stride(from: 0, to: frame.payload.count, by: 2) {
                let sample = Double(Int16(bitPattern: UInt16(frame.payload[index]) | UInt16(frame.payload[index + 1]) << 8)) / 32768
                sumSquares += sample * sample
                peak = max(peak, abs(sample))
            }
            // This transport validator consumes each frame immediately. The Mac app
            // separately verifies real HAL consumption before sending its ACKs.
            send(CamMicFrame(kind: .acknowledgement, sessionID: frame.sessionID, sequence: frame.sequence))
            signalOnce()
        }
    }

    private func send(_ frame: CamMicFrame) {
        guard let data = try? CamMicFrameCodec.encode(frame) else { fail("frame encoding failed"); return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.fail("frame send failed") }
        })
    }

    func waitForFirstResult() -> Snapshot {
        _ = firstResult.wait(timeout: .now() + 4)
        return snapshot()
    }

    func snapshot() -> Snapshot {
        queue.sync {
            Snapshot(packets: packets, bytes: bytes, rms: bytes > 0 ? sqrt(sumSquares / Double(bytes / 2)) : 0,
                     peak: peak, failure: failure, session: sequence?.sessionID, cipher: cipher, state: lastState)
        }
    }

    func stop() {
        queue.sync {
            active = false
            connection.stateUpdateHandler = nil
            connection.cancel()
            decoder = CamMicFrameDecoder()
            sequence = nil
        }
    }
}

private func reject(_ key: Data, identity: Data = CamMicPairing.usbTLSPSKIdentity, label: String) throws {
    let probe = AudioProbe(key: key, identity: identity)
    probe.start()
    let result = probe.waitForFirstResult()
    probe.stop()
    try require(result.packets == 0 && result.failure != nil,
                "\(label) was accepted or did not explicitly fail; state=\(result.state)")
    print("PASS \(label): no authenticated HELLO/PCM; \(result.failure!)")
    Thread.sleep(forTimeInterval: 0.15)
}

@discardableResult
private func authenticate(_ key: Data, duplicateCheck: Bool = false) throws -> Data {
    let primary = AudioProbe(key: key)
    primary.start()
    defer { primary.stop() }
    let first = primary.waitForFirstResult()
    try require(first.packets > 0 && first.failure == nil, "current key did not complete TLS + HELLO/READY + PCM")
    if duplicateCheck { try reject(key, label: "second concurrent Mac audio session") }
    Thread.sleep(forTimeInterval: 2)
    let value = primary.snapshot()
    try require(value.failure == nil && value.packets > first.packets && value.peak > 0 && value.rms > 0,
                "PCM did not continue, was silent, or primary session was displaced")
    print(String(format: "PASS TLS-PSK + HELLO/READY + PCM: packets=%llu bytes=%llu rms=%.6f peak=%.6f cipher=0x%04X",
                 value.packets, value.bytes, value.rms, value.peak, value.cipher ?? 0))
    return value.session!
}

private func waitForOperator(_ prompt: String) throws {
    print(prompt)
    fflush(stdout)
    var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
    try require(poll(&descriptor, 1, 180_000) > 0 && readLine() != nil, "operator confirmation deadline exceeded")
}

@main
private enum USBHandshakeValidation {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--help"] {
                print("Usage: run-usb-handshake-validation.sh [--lifecycle]\nRequires the explicit USB iproxy forwarding and a foreground iPhone USB probe. Stop the Mac app's audio session first. Operator prompts have a 180-second deadline.")
                return
            }
            try require(arguments.isEmpty || arguments == ["--lifecycle"], "unrecognized arguments; use --help")
            let lifecycle = arguments == ["--lifecycle"]
            var currentKey = try fetchSessionKey()
            defer { currentKey.resetBytes(in: 0..<currentKey.count) }
            print("PASS USB init: valid bounded response, session key held only in memory")
            let oldSession = try authenticate(currentKey)
            Thread.sleep(forTimeInterval: 0.15)
            var wrongKey = try CamMicPairing.newSessionKey()
            defer { wrongKey.resetBytes(in: 0..<wrongKey.count) }
            try reject(wrongKey, label: "wrong key")
            try reject(currentKey, identity: Data("CamMic-invalid-test-identity".utf8), label: "wrong PSK identity")
            let replacement = try authenticate(currentKey, duplicateCheck: true)
            try require(oldSession != replacement, "reconnect reused the old protocol session")
            print("PASS reconnect: fresh session ID and sequence; no old PCM accepted")
            if lifecycle {
                try waitForOperator("WAIT_STOP: stop capture on the iPhone, then press Return here")
                do {
                    var unexpected = try fetchSessionKey()
                    unexpected.resetBytes(in: 0..<unexpected.count)
                    throw ProbeFailure(description: "stopped capture still exposed init material")
                } catch let failure as ProbeFailure where failure.description == "stopped capture still exposed init material" {
                    throw failure
                } catch { print("PASS stopped capture: init material unavailable") }
                try reject(currentKey, label: "new audio connection while capture stopped")
                try waitForOperator("WAIT_RESTART: explicitly restart the USB probe on the iPhone, then press Return here")
                var newKey = try fetchSessionKey()
                defer { newKey.resetBytes(in: 0..<newKey.count) }
                try require(newKey != currentKey, "capture restart reused the old key")
                print("PASS restart: fresh random session key (material redacted)")
                try reject(currentKey, label: "prior capture key")
                let restarted = try authenticate(newKey)
                try require(restarted != replacement && restarted != oldSession, "restart reused an old protocol session")
                print("PASS capture lifecycle and stale-session rejection")
            }
            print("PASS validation complete; this client never attempts Wi-Fi")
        } catch {
            fputs("FAIL USB validation: \(error)\n", stderr)
            exit(1)
        }
    }
}
