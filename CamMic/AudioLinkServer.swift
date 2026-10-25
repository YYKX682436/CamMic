import Foundation
import Network
import Dispatch

/// iPhone is the only listener. A fresh 8-digit code configures TLS-PSK for each capture run.
final class AudioLinkServer {
    static let port = NWEndpoint.Port(rawValue: CamMicFrameCodec.tcpPort)!

    struct ListenerRun {
        let pairingCode: String
        let generation: UUID
    }

    var onStatus: ((String) -> Void)?

    var metricsSnapshot: (acknowledgements: UInt64, averageRTTMilliseconds: Double, maximumRTTMilliseconds: Double, inFlight: UInt64) {
        stateLock.lock()
        let activeWindow = window
        let values = (acknowledgementCount, averageRTTMilliseconds, maximumRTTMilliseconds)
        stateLock.unlock()
        return (values.0, values.1, values.2, activeWindow?.inFlightCount ?? 0)
    }

    private let queue = DispatchQueue(label: "com.yykx682436.CamMic.network-server", qos: .userInitiated)
    private let stateLock = NSLock()
    private var listener: NWListener?
    private var connection: NWConnection?
    private var sessionID: Data?
    private var window: CamMicAcknowledgementWindow?
    private var running = false
    private var ready = false
    private var readyAtNanoseconds: UInt64?
    private var generation = UUID()
    private var statusRevision = UUID()
    private var activeConnectionToken: UUID?
    private var sentAtNanoseconds: [UInt64: UInt64] = [:]
    private var acknowledgementCount: UInt64 = 0
    private var averageRTTMilliseconds = 0.0
    private var maximumRTTMilliseconds = 0.0
    private var decoder = CamMicFrameDecoder()

    func start() throws -> ListenerRun {
        precondition(Thread.isMainThread)
        stop()
        let newCode = CamMicPairing.newCode()
        let newListener = try NWListener(using: CamMicPairing.makeNetworkParameters(pairingCode: newCode), on: Self.port)
        let token = UUID()
        stateLock.lock()
        generation = token
        listener = newListener
        running = true
        readyAtNanoseconds = nil
        stateLock.unlock()

        newListener.stateUpdateHandler = { [weak self] state in
            guard let self = self, self.isListenerCurrent(token) else { return }
            switch state {
            case .ready:
                self.publish("正在监听 iPhone TCP/TLS 端口 50888；等待 Mac 输入配对码连接。")
            case .failed(let error):
                self.failListener(token: token, error: error)
            case .cancelled:
                break
            default:
                break
            }
        }
        newListener.newConnectionHandler = { [weak self] newConnection in
            self?.accept(newConnection, token: token)
        }
        newListener.start(queue: queue)
        return ListenerRun(pairingCode: newCode, generation: token)
    }

    func stop() {
        stateLock.lock()
        let oldListener = listener
        let oldConnection = connection
        let oldWindow = window
        listener = nil
        connection = nil
        window = nil
        activeConnectionToken = nil
        sentAtNanoseconds.removeAll(keepingCapacity: false)
        acknowledgementCount = 0
        averageRTTMilliseconds = 0
        maximumRTTMilliseconds = 0
        sessionID = nil
        ready = false
        readyAtNanoseconds = nil
        running = false
        generation = UUID()
        statusRevision = UUID()
        stateLock.unlock()

        oldWindow?.stop()
        oldConnection?.cancel()
        oldListener?.cancel()
    }

    /// Called by the audio worker. It waits only on a fixed cumulative-ACK window.
    func sendAudio(_ pcm: Data, listenerGeneration: UUID, capturedAtNanoseconds: UInt64) {
        guard pcm.count == CamMicFrameCodec.audioPayloadLength else { return }
        stateLock.lock()
        guard running, generation == listenerGeneration, ready,
              let readyAt = readyAtNanoseconds, capturedAtNanoseconds >= readyAt else {
            stateLock.unlock()
            return
        }
        let currentConnection = connection
        let currentSessionID = sessionID
        let currentWindow = window
        let currentConnectionToken = activeConnectionToken
        stateLock.unlock()
        guard let connection = currentConnection, let sessionID = currentSessionID,
              let window = currentWindow, let token = currentConnectionToken else { return }

        guard let sequence = window.acquireNextSequence(timeout: 1.25) else {
            if isCurrent(token, connection: connection) {
                failConnection(token: token, message: "Mac 没有及时确认音频，连接已重置。")
            }
            return
        }
        guard isCurrent(token, connection: connection) else { return }
        do {
            let data = try CamMicFrameCodec.encode(
                CamMicFrame(kind: .audio, sessionID: sessionID, sequence: sequence, payload: pcm)
            )
            stateLock.lock()
            guard running, activeConnectionToken == token, self.connection === connection else {
                stateLock.unlock()
                return
            }
            sentAtNanoseconds[sequence] = DispatchTime.now().uptimeNanoseconds
            stateLock.unlock()
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let error = error, let self = self else { return }
                self.failConnection(token: token, message: "音频发送失败：\(error.localizedDescription)")
            })
        } catch {
            failConnection(token: token, message: "音频帧编码失败，连接已重置。")
        }
    }

    private func accept(_ newConnection: NWConnection, token: UUID) {
        stateLock.lock()
        guard running, generation == token, connection == nil else {
            stateLock.unlock()
            newConnection.cancel()
            return
        }
        let newSessionID = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let connectionToken = UUID()
        let newWindow = CamMicAcknowledgementWindow(maximumInFlight: 8)
        connection = newConnection
        activeConnectionToken = connectionToken
        sessionID = newSessionID
        window = newWindow
        sentAtNanoseconds.removeAll(keepingCapacity: true)
        acknowledgementCount = 0
        averageRTTMilliseconds = 0
        maximumRTTMilliseconds = 0
        ready = false
        readyAtNanoseconds = nil
        decoder = CamMicFrameDecoder()
        stateLock.unlock()

        publish("Mac 已连接，正在检查配对和音频格式…")
        newConnection.stateUpdateHandler = { [weak self] state in
            guard let self = self, self.isCurrent(connectionToken, connection: newConnection) else { return }
            switch state {
            case .ready:
                self.sendHello(connection: newConnection, sessionID: newSessionID, token: connectionToken)
                self.receiveNext(connection: newConnection, sessionID: newSessionID, token: connectionToken)
            case .failed(let error):
                self.failConnection(token: connectionToken, message: "Mac 连接失败：\(error.localizedDescription)")
            case .cancelled:
                self.connectionEnded(token: connectionToken, message: "Mac 已断开；等待重新连接。")
            default:
                break
            }
        }
        newConnection.start(queue: queue)
    }

    private func sendHello(connection: NWConnection, sessionID: Data, token: UUID) {
        var payload = Data()
        Self.append(CamMicFrameCodec.sampleRate, to: &payload)
        Self.append(CamMicFrameCodec.channelCount, to: &payload)
        Self.append(CamMicFrameCodec.bitsPerSample, to: &payload)
        Self.append(CamMicFrameCodec.samplesPerFrame, to: &payload)
        do {
            let hello = try CamMicFrameCodec.encode(CamMicFrame(kind: .hello, sessionID: sessionID, payload: payload))
            connection.send(content: hello, completion: .contentProcessed { [weak self] error in
                if let error = error {
                    self?.failConnection(token: token, message: "握手发送失败：\(error.localizedDescription)")
                }
            })
        } catch {
            failConnection(token: token, message: "无法发送协议握手。")
        }
    }

    private func receiveNext(connection: NWConnection, sessionID: Data, token: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
            guard let self = self, self.isCurrent(token, connection: connection) else { return }
            if let data = data, !data.isEmpty {
                do {
                    let frames = try self.decoder.append(data)
                    for frame in frames {
                        try self.process(frame, expectedSessionID: sessionID, connection: connection, token: token)
                    }
                } catch {
                    self.failConnection(token: token, message: "握手或确认帧无效，连接已关闭。")
                    return
                }
            }
            if let error = error {
                self.failConnection(token: token, message: "连接接收失败：\(error.localizedDescription)")
            } else if complete {
                self.connectionEnded(token: token, message: "Mac 已断开；等待重新连接。")
            } else {
                self.receiveNext(connection: connection, sessionID: sessionID, token: token)
            }
        }
    }

    private func process(
        _ frame: CamMicFrame,
        expectedSessionID: Data,
        connection: NWConnection,
        token: UUID
    ) throws {
        guard frame.sessionID == expectedSessionID else { throw CamMicProtocolError.wrongSession }
        if frame.kind == .ready {
            guard frame.sequence == 0 else { throw CamMicProtocolError.invalidSequence }
            stateLock.lock()
            guard activeConnectionToken == token, self.connection === connection, !ready else {
                stateLock.unlock()
                throw CamMicProtocolError.invalidSequence
            }
            ready = true
            readyAtNanoseconds = DispatchTime.now().uptimeNanoseconds
            stateLock.unlock()
            publish("Mac 已配对并就绪；正在持续发送 48 kHz 单声道音频。")
        } else if frame.kind == .acknowledgement {
            guard frame.sequence > 0 else { throw CamMicProtocolError.invalidSequence }
            stateLock.lock()
            let activeWindow = activeConnectionToken == token && self.connection === connection ? window : nil
            stateLock.unlock()
            guard let activeWindow = activeWindow else { throw CamMicProtocolError.wrongSession }
            try activeWindow.acknowledge(frame.sequence)
            let now = DispatchTime.now().uptimeNanoseconds
            stateLock.lock()
            if let sentAt = sentAtNanoseconds[frame.sequence], now >= sentAt {
                let duration = Double(now - sentAt) / 1_000_000
                acknowledgementCount += 1
                averageRTTMilliseconds += (duration - averageRTTMilliseconds) / Double(acknowledgementCount)
                maximumRTTMilliseconds = max(maximumRTTMilliseconds, duration)
            }
            let completedSequences = sentAtNanoseconds.keys.filter { $0 <= frame.sequence }
            for oldSequence in completedSequences {
                sentAtNanoseconds.removeValue(forKey: oldSequence)
            }
            stateLock.unlock()
        } else {
            throw CamMicProtocolError.invalidSequence
        }
    }

    private func failListener(token: UUID, error: NWError) {
        stateLock.lock()
        guard generation == token else { stateLock.unlock(); return }
        running = false
        listener = nil
        let oldConnection = connection
        connection = nil
        activeConnectionToken = nil
        let oldWindow = window
        window = nil
        sentAtNanoseconds.removeAll(keepingCapacity: false)
        sessionID = nil
        ready = false
        readyAtNanoseconds = nil
        stateLock.unlock()
        oldWindow?.stop()
        oldConnection?.cancel()
        publish("无法监听本地端口：\(error.localizedDescription)")
    }

    private func failConnection(token: UUID, message: String) {
        stateLock.lock()
        let current = activeConnectionToken == token ? connection : nil
        stateLock.unlock()
        current?.cancel()
        connectionEnded(token: token, message: message)
    }

    private func connectionEnded(token: UUID, message: String) {
        stateLock.lock()
        guard activeConnectionToken == token else { stateLock.unlock(); return }
        let oldWindow = window
        window = nil
        connection = nil
        activeConnectionToken = nil
        sentAtNanoseconds.removeAll(keepingCapacity: false)
        sessionID = nil
        ready = false
        readyAtNanoseconds = nil
        let stillListening = running
        stateLock.unlock()
        oldWindow?.stop()
        publish(stillListening ? message : "采音已停止。")
    }

    private func isListenerCurrent(_ token: UUID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running && generation == token
    }

    private func isCurrent(_ token: UUID, connection: NWConnection) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running && activeConnectionToken == token && self.connection === connection
    }

    private func publish(_ message: String) {
        let revision = UUID()
        stateLock.lock()
        statusRevision = revision
        stateLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.stateLock.lock()
            let isLatest = self.statusRevision == revision
            self.stateLock.unlock()
            if isLatest { self.onStatus?(message) }
        }
    }

    private static func append(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}
