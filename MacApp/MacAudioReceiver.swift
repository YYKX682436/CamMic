import CamMicShared
import Foundation
import Network

final class MacAudioReceiver {
    struct Metrics {
        let queuedPackets: Int
        let queuedFrames: Int
        let receivedPackets: UInt64
        let protocolErrors: UInt64
        let underrunCallbacks: UInt64
        let lastConsumedSequence: UInt64
    }

    var onStatus: ((String) -> Void)?
    var onMetrics: ((Metrics) -> Void)?

    private let queue = DispatchQueue(label: "com.yykx682436.CamMic.mac-network", qos: .userInitiated)
    private let stateLock = NSLock()
    private var generation = UUID()
    private var connection: NWConnection?
    private var output: AudioDeviceOutput?
    private var outputDevice: AudioOutputDevice?
    private var activeSessionID: Data?
    private var receiveSequence: CamMicReceiveSequence?
    private var decoder = CamMicFrameDecoder()
    private var acknowledgementTimer: DispatchSourceTimer?
    private var diagnosticsTimer: DispatchSourceTimer?
    private var acknowledgementInFlight = false
    private var lastAcknowledgementSent: UInt64 = 0
    private var receivedPackets: UInt64 = 0
    private var protocolErrors: UInt64 = 0
    private var metricsUpdatePending = false
    private var metricsPendingToken: UUID?

    func connect(host: String, pairingCode: String, device: AudioOutputDevice) {
        let token = UUID()
        stateLock.lock()
        generation = token
        stateLock.unlock()
        queue.async { [weak self] in
            guard let self = self, self.isCurrent(token) else { return }
            self.stopResources()
            do {
                guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.publish("请填写 iPhone 的局域网 IP，或 USB 代理地址 127.0.0.1。", token: token)
                    return
                }
                guard pairingCode.count == 8, pairingCode.allSatisfy(\.isNumber) else {
                    self.publish("配对码应为 iPhone 当前显示的 8 位数字。", token: token)
                    return
                }
                let freshDevice = AudioDeviceCatalog.device(uid: device.uid)
                guard let selected = freshDevice, selected.id == device.id else { throw AudioDeviceError.missingDevice }
                let output = try AudioDeviceOutput(device: selected)
                try output.start()
                self.output = output
                self.outputDevice = selected

                let connection = NWConnection(
                    host: NWEndpoint.Host(host),
                    port: NWEndpoint.Port(rawValue: CamMicFrameCodec.tcpPort)!,
                    using: CamMicPairing.makeNetworkParameters(pairingCode: pairingCode)
                )
                self.connection = connection
                connection.stateUpdateHandler = { [weak self] state in
                    guard let self = self, self.isCurrent(token), self.connection === connection else { return }
                    switch state {
                    case .ready:
                        self.publish("TLS 配对成功，等待 iPhone 音频协议握手…", token: token)
                        self.receiveNext(connection: connection, token: token)
                    case .failed(let error):
                        self.endSession(token: token, message: "连接失败或配对码不匹配：\(error.localizedDescription)")
                    case .cancelled:
                        self.endSession(token: token, message: "连接已断开；输出已静音并清空缓冲。")
                    default:
                        break
                    }
                }
                connection.start(queue: self.queue)
                self.publish("正在连接 \(host):50888；直接输出到所选设备，不监听 Mac 扬声器。", token: token)
            } catch {
                self.stopResources()
                self.publish("无法启动所选输出设备：\(error.localizedDescription)", token: token)
            }
        }
    }

    func disconnect() {
        let token = UUID()
        stateLock.lock()
        generation = token
        stateLock.unlock()
        queue.async { [weak self] in
            guard let self = self, self.isCurrent(token) else { return }
            self.publishCurrentMetrics(token: token)
            self.stopResources()
            self.publish("已断开；输出静音，旧会话缓冲已清空。", token: token)
        }
    }

    private func receiveNext(connection: NWConnection, token: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
            guard let self = self, self.isCurrent(token), self.connection === connection else { return }
            if let data = data, !data.isEmpty {
                do {
                    let frames = try self.decoder.append(data)
                    for frame in frames { try self.process(frame, connection: connection, token: token) }
                } catch {
                    self.protocolErrors += 1
                    self.endSession(token: token, message: "收到无效协议帧；连接已重置并清空缓冲。")
                    return
                }
            }
            if let error = error {
                self.endSession(token: token, message: "接收失败；输出已静音：\(error.localizedDescription)")
            } else if complete {
                self.endSession(token: token, message: "iPhone 已断开；输出静音并清空缓冲。")
            } else {
                self.receiveNext(connection: connection, token: token)
            }
        }
    }

    private func process(_ frame: CamMicFrame, connection: NWConnection, token: UUID) throws {
        guard self.connection === connection else { throw CamMicProtocolError.wrongSession }
        if frame.kind == .hello {
            guard activeSessionID == nil, frame.sequence == 0,
                  frame.payload.count == 12,
                  Self.readUInt32(frame.payload, 0) == CamMicFrameCodec.sampleRate,
                  Self.readUInt16(frame.payload, 4) == CamMicFrameCodec.channelCount,
                  Self.readUInt16(frame.payload, 6) == CamMicFrameCodec.bitsPerSample,
                  Self.readUInt32(frame.payload, 8) == CamMicFrameCodec.samplesPerFrame,
                  let output = output else { throw CamMicProtocolError.invalidPayloadLength }
            activeSessionID = frame.sessionID
            receiveSequence = try CamMicReceiveSequence(sessionID: frame.sessionID)
            decoder = CamMicFrameDecoder()
            let ready = try CamMicFrameCodec.encode(CamMicFrame(kind: .ready, sessionID: frame.sessionID))
            connection.send(content: ready, completion: .contentProcessed { [weak self] error in
                guard let self = self, self.isCurrent(token) else { return }
                if let error = error {
                    self.endSession(token: token, message: "握手响应失败：\(error.localizedDescription)")
                } else {
                    self.startTimers(output: output, token: token)
                    self.publish("已配对；人声正通过 \(self.outputDevice?.name ?? "所选设备") 输出。", token: token)
                }
            })
        } else if frame.kind == .audio {
            guard activeSessionID != nil, let currentID = activeSessionID, frame.sessionID == currentID,
                  var sequence = receiveSequence, let output = output else {
                throw CamMicProtocolError.wrongSession
            }
            try sequence.accept(frame)
            receiveSequence = sequence
            do {
                try output.enqueue(pcm16LittleEndian: frame.payload, sequence: frame.sequence)
                output.markPlaybackActive()
                receivedPackets += 1
            } catch {
                protocolErrors += 1
                throw error
            }
        } else {
            throw CamMicProtocolError.invalidSequence
        }
    }

    private func startTimers(output: AudioDeviceOutput, token: UUID) {
        guard acknowledgementTimer == nil else { return }
        let acknowledgement = DispatchSource.makeTimerSource(queue: queue)
        acknowledgement.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(3))
        acknowledgement.setEventHandler { [weak self, weak output] in
            guard let self = self, let output = output, self.isCurrent(token) else { return }
            self.sendAvailableAcknowledgement(output: output, token: token)
        }
        acknowledgementTimer = acknowledgement
        acknowledgement.resume()

        let diagnostics = DispatchSource.makeTimerSource(queue: queue)
        diagnostics.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1), leeway: .milliseconds(50))
        diagnostics.setEventHandler { [weak self, weak output] in
            guard let self = self, let output = output, self.isCurrent(token) else { return }
            self.checkDeviceAndPublishMetrics(output: output, token: token)
        }
        diagnosticsTimer = diagnostics
        diagnostics.resume()
    }

    private func sendAvailableAcknowledgement(output: AudioDeviceOutput, token: UUID) {
        guard !acknowledgementInFlight, let connection = connection, let sessionID = activeSessionID else { return }
        let consumed = output.metrics.lastConsumed
        guard consumed > lastAcknowledgementSent else { return }
        do {
            let frame = try CamMicFrameCodec.encode(
                CamMicFrame(kind: .acknowledgement, sessionID: sessionID, sequence: consumed)
            )
            acknowledgementInFlight = true
            connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                guard let self = self, self.isCurrent(token) else { return }
                self.acknowledgementInFlight = false
                if let error = error {
                    self.endSession(token: token, message: "确认帧发送失败：\(error.localizedDescription)")
                } else {
                    self.lastAcknowledgementSent = max(self.lastAcknowledgementSent, consumed)
                }
            })
        } catch {
            endSession(token: token, message: "无法编码累计确认帧。")
        }
    }

    private func checkDeviceAndPublishMetrics(output: AudioDeviceOutput, token: UUID) {
        guard let original = outputDevice,
              let current = AudioDeviceCatalog.device(uid: original.uid),
              current.id == original.id,
              Self.hasSameOutputFormat(current, original) else {
            endSession(token: token, message: "所选输出设备消失或格式改变；连接已停止，没有切换到扬声器。")
            return
        }
        let value = output.metrics
        publishMetrics(Metrics(
            queuedPackets: value.queuedPackets,
            queuedFrames: value.queuedFrames,
            receivedPackets: receivedPackets,
            protocolErrors: protocolErrors,
            underrunCallbacks: value.underruns,
            lastConsumedSequence: value.lastConsumed
        ), token: token)
    }

    private func endSession(token: UUID, message: String) {
        guard isCurrent(token) else { return }
        publishCurrentMetrics(token: token)
        stopResources()
        publish(message, token: token)
    }

    private func publishCurrentMetrics(token: UUID) {
        guard let output = output else { return }
        let value = output.metrics
        publishMetrics(Metrics(
            queuedPackets: value.queuedPackets,
            queuedFrames: value.queuedFrames,
            receivedPackets: receivedPackets,
            protocolErrors: protocolErrors,
            underrunCallbacks: value.underruns,
            lastConsumedSequence: value.lastConsumed
        ), token: token)
    }

    private func stopResources() {
        let oldConnection = connection
        connection = nil
        oldConnection?.stateUpdateHandler = nil
        oldConnection?.cancel()
        acknowledgementTimer?.setEventHandler {}
        acknowledgementTimer?.cancel()
        acknowledgementTimer = nil
        diagnosticsTimer?.setEventHandler {}
        diagnosticsTimer?.cancel()
        diagnosticsTimer = nil
        output?.stopAndClear()
        output = nil
        outputDevice = nil
        activeSessionID = nil
        receiveSequence = nil
        decoder = CamMicFrameDecoder()
        acknowledgementInFlight = false
        lastAcknowledgementSent = 0
        receivedPackets = 0
        protocolErrors = 0
    }

    private func isCurrent(_ token: UUID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generation == token
    }

    private func publish(_ message: String, token: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isCurrent(token) else { return }
            self.onStatus?(message)
        }
    }

    private func publishMetrics(_ metrics: Metrics, token: UUID) {
        stateLock.lock()
        guard generation == token else { stateLock.unlock(); return }
        guard !metricsUpdatePending else { stateLock.unlock(); return }
        metricsUpdatePending = true
        metricsPendingToken = token
        stateLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.stateLock.lock()
            let ownsPendingUpdate = self.metricsPendingToken == token
            if ownsPendingUpdate {
                self.metricsUpdatePending = false
                self.metricsPendingToken = nil
            }
            let isCurrent = self.generation == token
            self.stateLock.unlock()
            if ownsPendingUpdate && isCurrent { self.onMetrics?(metrics) }
        }
    }

    private static func hasSameOutputFormat(_ lhs: AudioOutputDevice, _ rhs: AudioOutputDevice) -> Bool {
        lhs.channelCount == rhs.channelCount &&
            lhs.format.mSampleRate == rhs.format.mSampleRate &&
            lhs.format.mFormatID == rhs.format.mFormatID &&
            lhs.format.mFormatFlags == rhs.format.mFormatFlags &&
            lhs.format.mBytesPerPacket == rhs.format.mBytesPerPacket &&
            lhs.format.mFramesPerPacket == rhs.format.mFramesPerPacket &&
            lhs.format.mBytesPerFrame == rhs.format.mBytesPerFrame &&
            lhs.format.mChannelsPerFrame == rhs.format.mChannelsPerFrame &&
            lhs.format.mBitsPerChannel == rhs.format.mBitsPerChannel
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16) |
            (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
    }
}
