import CamMicShared
import CamMicMacCore
import Foundation
import Network

final class MacAudioReceiver: CamMicUSBReceiving {
    struct Metrics {
        let queuedPackets: Int
        let queuedFrames: Int
        let outputSampleRate: Double
        let receivedPackets: UInt64
        let receivedPCMBytes: UInt64
        let receivedPCMRMS: Double
        let receivedPCMPeak: Double
        let protocolErrors: UInt64
        let underrunCallbacks: UInt64
        let renderContentions: UInt64
        let lastConsumedSequence: UInt64
    }

    var onStatus: ((String) -> Void)?
    var onMetrics: ((Metrics) -> Void)?
    var onMuteState: ((Bool) -> Void)?
    var onUSBAttemptEnded: ((UUID, String) -> Void)?
    var onUSBHandshakeReady: ((UUID) -> Void)?

    private let queue = DispatchQueue(label: "com.yykx682436.CamMic.mac-network", qos: .userInitiated)
    private let stateLock = NSLock()
    private let eventDelivery: (@escaping () -> Void) -> Void
    private let audioEndpoints: () -> CamMicAudioEndpoints?
    private let audioEndpointsAreCurrent: (CamMicAudioEndpoints) -> Bool
    private let outputFactory: (AudioOutputDevice) throws -> MacAudioOutputControlling
    private var generation = UUID()
    private var connection: NWConnection?
    private var initializationConnection: NWConnection?
    private enum Transport { case wifi, usb }
    private var activeTransport: Transport?
    private var usbAudioPortForCurrentAttempt: UInt16 = 50890
    private var isMuted = false
    private var output: MacAudioOutputControlling?
    private var outputDevice: AudioOutputDevice?
    private var microphoneDevice: AudioInputDevice?
    private var activeSessionID: Data?
    private var receiveSequence: CamMicReceiveSequence?
    private var decoder = CamMicFrameDecoder()
    private var acknowledgementTimer: DispatchSourceTimer?
    private var diagnosticsTimer: DispatchSourceTimer?
    private var acknowledgementInFlight = false
    private var lastAcknowledgementSent: UInt64 = 0
    private var receivedPackets: UInt64 = 0
    private var receivedPCMBytes: UInt64 = 0
    private var receivedPCMRMS: Double = 0
    private var receivedPCMPeak: Double = 0
    private var protocolErrors: UInt64 = 0
    private var metricsUpdatePending = false
    private var metricsPendingToken: UUID?

    init(eventDelivery: @escaping (@escaping () -> Void) -> Void = { action in
        DispatchQueue.main.async(execute: action)
    },
    audioEndpoints: @escaping () -> CamMicAudioEndpoints? = { CamMicAudioDevices.current() },
    audioEndpointsAreCurrent: @escaping (CamMicAudioEndpoints) -> Bool = { endpoints in
        endpoints.microphone.name == CamMicAudioDeviceIdentity.publicInputName &&
            endpoints.appOutput.name == CamMicAudioDeviceIdentity.hiddenOutputName &&
            AudioDeviceCatalog.isCurrentInput(endpoints.microphone) &&
            AudioDeviceCatalog.isCurrentOutput(endpoints.appOutput)
    },
    outputFactory: @escaping (AudioOutputDevice) throws -> MacAudioOutputControlling = { try AudioDeviceOutput(device: $0) }) {
        self.eventDelivery = eventDelivery
        self.audioEndpoints = audioEndpoints
        self.audioEndpointsAreCurrent = audioEndpointsAreCurrent
        self.outputFactory = outputFactory
    }

    func connect(host: String, pairingCode: String) {
        let token = UUID()
        stateLock.lock()
        generation = token
        stateLock.unlock()
        queue.async { [weak self] in
            guard let self = self, self.isCurrent(token) else { return }
            self.stopResources()
            self.activeTransport = .wifi
            do {
                guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.publish("请填写 iPhone 的局域网 IP，或 USB 代理地址 127.0.0.1。", token: token)
                    return
                }
                guard pairingCode.count == 8, pairingCode.allSatisfy(\.isNumber) else {
                    self.publish("配对码应为 iPhone 当前显示的 8 位数字。", token: token)
                    return
                }
                guard let endpoints = self.audioEndpoints(), self.audioEndpointsAreCurrent(endpoints) else {
                    throw AudioDeviceError.missingCamMic
                }
                let microphone = endpoints.microphone
                let selected = endpoints.appOutput
                let output = try self.outputFactory(selected)
                try output.start()
                output.setMuted(self.isMuted)
                self.output = output
                self.outputDevice = selected
                self.microphoneDevice = microphone
                self.startDeviceMonitoring(output: output, token: token)

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
                        self.publish("TLS 传输已连接，等待 CamMic 协议握手…", token: token)
                        self.receiveNext(connection: connection, token: token)
                    case .failed(let error):
                        self.endSession(token: token, message: "传输/TLS 阶段失败，协议握手尚未开始：\(error.localizedDescription)。USB 连接请先确认 XR 已被 USBMux 识别且 50888 端口转发正在运行；若错误来自 TLS，请刷新当前 8 位配对码。")
                    case .cancelled:
                        self.endSession(token: token, message: "连接已断开；输出已静音并清空缓冲。")
                    default:
                        break
                    }
                }
                connection.start(queue: self.queue)
                self.publish("正在连接 \(host):50888；iPhone 音频写入 CamMic 专用端点，Mac 默认扬声器保持不变。", token: token)
            } catch let error as AudioDeviceError {
                self.stopResources()
                if case .missingCamMic = error {
                    self.publish("未检测到 CamMic 麦克风或内部输出端。请先使用“安装或修复音频组件”，再连接 iPhone。", token: token)
                } else {
                    self.publish("CamMic 内部音频输出初始化失败：\(error.localizedDescription)", token: token)
                }
            } catch {
                self.stopResources()
                self.publish("CamMic 连接初始化失败：\(error.localizedDescription)", token: token)
            }
        }
    }

    /// Uses only the app-owned loopback forwarders supplied by the USBMux manager.
    /// The USB path never accepts an IP address and never falls back to Wi-Fi.
    @discardableResult
    func connectUSB(initializationPort: UInt16, audioPort: UInt16) -> UUID {
        let token = UUID()
        stateLock.lock()
        generation = token
        stateLock.unlock()
        queue.async { [weak self] in
            guard let self = self, self.isCurrent(token) else { return }
            self.stopResources()
            self.activeTransport = .usb
            self.usbAudioPortForCurrentAttempt = audioPort
            do {
                guard let endpoints = self.audioEndpoints(), self.audioEndpointsAreCurrent(endpoints) else {
                    throw AudioDeviceError.missingCamMic
                }
                let microphone = endpoints.microphone
                let selected = endpoints.appOutput
                let output = try self.outputFactory(selected)
                try output.start()
                output.setMuted(self.isMuted)
                self.output = output
                self.outputDevice = selected
                self.microphoneDevice = microphone
                self.startDeviceMonitoring(output: output, token: token)

                let initialization = NWConnection(
                    host: .ipv4(.loopback),
                    port: NWEndpoint.Port(rawValue: initializationPort)!,
                    using: .tcp
                )
                self.initializationConnection = initialization
                initialization.stateUpdateHandler = { [weak self] state in
                    guard let self = self, self.isCurrent(token),
                          self.initializationConnection === initialization else { return }
                    switch state {
                    case .ready:
                        self.publish("USB 已连接，正在建立加密音频会话…", token: token)
                        self.requestUSBSessionMaterial(connection: initialization, token: token)
                    case .failed, .waiting:
                        self.endSession(token: token, message: "USB 初始化失败。请确认 iPhone 已启动 CamMic 采音。")
                    case .cancelled:
                        self.endSession(token: token, message: "USB 连接已断开，输出已静音。")
                    default:
                        break
                    }
                }
                initialization.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + .seconds(5)) { [weak self, weak initialization] in
                    guard let self = self, let initialization = initialization,
                          self.isCurrent(token), self.initializationConnection === initialization else { return }
                    self.endSession(token: token, message: "USB 初始化超时；输出已静音并清空缓冲。")
                }
                self.publish("正在连接 iPhone…", token: token)
            } catch let error as AudioDeviceError {
                self.stopResources()
                if case .missingCamMic = error {
                    self.publish("未检测到 CamMic 麦克风。请先安装或修复音频组件。", token: token)
                } else {
                    self.publish("CamMic 内部音频输出初始化失败：\(error.localizedDescription)", token: token)
                }
                self.onUSBAttemptEnded?(token, error.localizedDescription)
            } catch {
                self.stopResources()
                self.publish("USB 连接失败，请重新插拔 iPhone。", token: token)
                self.onUSBAttemptEnded?(token, error.localizedDescription)
            }
        }
        return token
    }

    private func requestUSBSessionMaterial(connection: NWConnection, token: UUID) {
        let request: (nonce: Data, message: Data)
        do {
            request = try CamMicUSBSessionMaterialCodec.makeRequest()
        } catch {
            endSession(token: token, message: "无法创建 USB 会话请求。")
            return
        }
        connection.send(content: request.message, completion: .contentProcessed { [weak self] error in
            guard let self = self, self.isCurrent(token),
                  self.initializationConnection === connection else { return }
            if error != nil {
                self.endSession(token: token, message: "USB 初始化请求发送失败。")
                return
            }
            self.receiveUSBSessionMaterial(
                connection: connection,
                token: token,
                expectedNonce: request.nonce,
                accumulated: Data()
            )
        })
    }

    private func receiveUSBSessionMaterial(
        connection: NWConnection,
        token: UUID,
        expectedNonce: Data,
        accumulated: Data
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: CamMicUSBSessionMaterialCodec.responseLength) { [weak self] data, _, complete, error in
            guard let self = self, self.isCurrent(token),
                  self.initializationConnection === connection else { return }
            if error != nil {
                self.endSession(token: token, message: "USB 初始化响应接收失败。")
                return
            }
            var bytes = accumulated
            if let data = data, !data.isEmpty { bytes.append(data) }
            guard bytes.count <= CamMicUSBSessionMaterialCodec.responseLength else {
                self.endSession(token: token, message: "USB 初始化响应长度无效。")
                return
            }
            if bytes.count == CamMicUSBSessionMaterialCodec.responseLength {
                do {
                    let key = try CamMicUSBSessionMaterialCodec.decodeResponse(bytes, expectedNonce: expectedNonce)
                    self.connectUSBAudio(preSharedKey: key, token: token, initialization: connection, audioPort: self.usbAudioPortForCurrentAttempt)
                } catch {
                    self.endSession(token: token, message: "USB 初始化响应无效。")
                }
            } else if complete {
                self.endSession(token: token, message: "USB 初始化通道提前关闭。")
            } else {
                self.receiveUSBSessionMaterial(
                    connection: connection,
                    token: token,
                    expectedNonce: expectedNonce,
                    accumulated: bytes
                )
            }
        }
    }

    private func connectUSBAudio(preSharedKey: Data, token: UUID, initialization: NWConnection, audioPort: UInt16) {
        guard isCurrent(token), initializationConnection === initialization else { return }
        initializationConnection = nil
        initialization.stateUpdateHandler = nil
        initialization.cancel()

        let audio = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: audioPort)!,
            using: CamMicPairing.makeNetworkParameters(
                preSharedKey: preSharedKey,
                identity: CamMicPairing.usbTLSPSKIdentity
            )
        )
        connection = audio
        audio.stateUpdateHandler = { [weak self] state in
            self?.handleUSBAudioState(state, audio: audio, token: token)
        }
        audio.start(queue: queue)
        queue.asyncAfter(deadline: .now() + .seconds(5)) { [weak self, weak audio] in
            guard let self = self, let audio = audio, self.isCurrent(token),
                  self.connection === audio, self.activeSessionID == nil else { return }
            self.endSession(token: token, message: "USB 音频握手超时，输出已静音。")
        }
        publish("正在建立 USB 音频连接…", token: token)
    }

    private func handleUSBAudioState(_ state: NWConnection.State, audio: NWConnection, token: UUID) {
        guard isCurrent(token), connection === audio else { return }
        switch state {
        case .ready:
            publish("USB 已连接，正在等待 iPhone 音频…", token: token)
            receiveNext(connection: audio, token: token)
        case .failed, .waiting:
            endSession(token: token, message: "USB TLS 认证或传输连接失败；输出已静音并清空缓冲。")
        case .cancelled:
            endSession(token: token, message: "USB 音频连接已关闭；输出已静音并清空缓冲。")
        default: break
        }
    }

    func disconnect(statusMessage: String = "已断开；输出静音，旧会话缓冲已清空。") {
        let token = UUID()
        stateLock.lock()
        generation = token
        metricsUpdatePending = false
        metricsPendingToken = nil
        stateLock.unlock()
        queue.async { [weak self] in
            guard let self = self, self.isCurrent(token) else { return }
            let finalMetrics = self.clearedMetricsSnapshot()
            self.stopResources()
            self.publishMetrics(finalMetrics, token: token)
            self.publish(statusMessage, token: token)
        }
    }

    func setMuted(_ muted: Bool) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.updateMutePreference(muted)
        }
    }

    func toggleMuted() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.updateMutePreference(!self.isMuted)
        }
    }

    private func updateMutePreference(_ muted: Bool) {
        isMuted = muted
        output?.setMuted(muted)
        eventDelivery { [weak self] in self?.onMuteState?(muted) }
        publish(muted ? "已静音。USB 连接仍保持。" : "已取消静音。", token: currentGeneration())
    }

    func shutdown() {
        stateLock.lock()
        generation = UUID()
        metricsUpdatePending = false
        metricsPendingToken = nil
        stateLock.unlock()
        queue.sync { [weak self] in self?.stopResources() }
    }

    private func receiveNext(connection: NWConnection, token: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
            guard let self = self, self.isCurrent(token), self.connection === connection else { return }
            if let data = data, !data.isEmpty {
                let frames: [CamMicFrame]
                do {
                    frames = try self.decoder.append(data)
                } catch {
                    self.protocolErrors += 1
                    self.endSession(token: token, message: "协议解码阶段收到无效帧；连接已重置并清空缓冲。")
                    return
                }
                for frame in frames {
                    do {
                        try self.process(frame, connection: connection, token: token)
                    } catch let error as AudioDeviceError {
                        self.endSession(token: token, message: "CamMic 音频输出阶段失败：\(error.localizedDescription)；协议帧有效，连接已停止并清空缓冲。")
                        return
                    } catch {
                        self.protocolErrors += 1
                        self.endSession(token: token, message: "CamMic 协议会话阶段失败：\(error.localizedDescription)；连接已停止并清空缓冲。")
                        return
                    }
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
                    self.startAcknowledgementTimer(output: output, token: token)
                    if self.activeTransport == .usb { self.onUSBHandshakeReady?(token) }
                    self.publish("已配对；iPhone 人声正送入系统麦克风 CamMic。", token: token)
                }
            })
        } else if frame.kind == .audio {
            guard activeSessionID != nil, let currentID = activeSessionID, frame.sessionID == currentID,
                  var sequence = receiveSequence, let output = output else {
                throw CamMicProtocolError.wrongSession
            }
            try sequence.accept(frame)
            receiveSequence = sequence
            receivedPackets += 1
            recordReceivedPCM(frame.payload)
            do {
                try output.enqueue(pcm16LittleEndian: frame.payload, sequence: frame.sequence)
                output.markPlaybackActive()
            } catch {
                throw error
            }
        } else {
            throw CamMicProtocolError.invalidSequence
        }
    }

    private func startDeviceMonitoring(output: MacAudioOutputControlling, token: UUID) {
        guard diagnosticsTimer == nil else { return }
        let diagnostics = DispatchSource.makeTimerSource(queue: queue)
        diagnostics.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1), leeway: .milliseconds(50))
        diagnostics.setEventHandler { [weak self, weak output] in
            guard let self = self, let output = output, self.isCurrent(token) else { return }
            self.checkDeviceAndPublishMetrics(output: output, token: token)
        }
        diagnosticsTimer = diagnostics
        diagnostics.resume()
    }

    private func startAcknowledgementTimer(output: MacAudioOutputControlling, token: UUID) {
        guard acknowledgementTimer == nil else { return }
        let acknowledgement = DispatchSource.makeTimerSource(queue: queue)
        acknowledgement.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(3))
        acknowledgement.setEventHandler { [weak self, weak output] in
            guard let self = self, let output = output, self.isCurrent(token) else { return }
            self.sendAvailableAcknowledgement(output: output, token: token)
        }
        acknowledgementTimer = acknowledgement
        acknowledgement.resume()
    }

    private func sendAvailableAcknowledgement(output: MacAudioOutputControlling, token: UUID) {
        guard !acknowledgementInFlight, let connection = connection, let sessionID = activeSessionID else { return }
        let consumed = output.metrics.lastConsumed
        guard consumed > lastAcknowledgementSent else { return }
        do {
            let frame = try Self.encodeAcknowledgement(sessionID: sessionID, consumedSequence: consumed)
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

    private func checkDeviceAndPublishMetrics(output: MacAudioOutputControlling, token: UUID) {
        guard let original = outputDevice,
              let originalInput = microphoneDevice,
              audioEndpointsAreCurrent(CamMicAudioEndpoints(microphone: originalInput, appOutput: original)),
              originalInput.name == CamMicAudioDeviceIdentity.publicInputName else {
            endSession(token: token, message: "CamMic 麦克风或内部输出端消失、重载或格式改变；连接已停止并静音，Mac 默认扬声器未切换。")
            return
        }
        let value = output.metrics
        publishMetrics(Metrics(
            queuedPackets: value.queuedPackets,
            queuedFrames: value.queuedFrames,
            outputSampleRate: outputDevice?.sampleRate ?? Double(CamMicFrameCodec.sampleRate),
            receivedPackets: receivedPackets,
            receivedPCMBytes: receivedPCMBytes,
            receivedPCMRMS: receivedPCMRMS,
            receivedPCMPeak: receivedPCMPeak,
            protocolErrors: protocolErrors,
            underrunCallbacks: value.underruns,
            renderContentions: value.renderContentions,
            lastConsumedSequence: value.lastConsumed
        ), token: token)
    }

    private func endSession(token: UUID, message: String) {
        guard isCurrent(token) else { return }
        let endedTransport = activeTransport
        let endedToken = UUID()
        stateLock.lock()
        guard generation == token else { stateLock.unlock(); return }
        generation = endedToken
        metricsUpdatePending = false
        metricsPendingToken = nil
        stateLock.unlock()

        let finalMetrics = clearedMetricsSnapshot()
        stopResources()
        publishMetrics(finalMetrics, token: endedToken)
        publish(message, token: endedToken)
        if endedTransport == .usb { onUSBAttemptEnded?(token, message) }
    }

    private func clearedMetricsSnapshot() -> Metrics {
        let value = output?.metrics
        return Metrics(
            queuedPackets: 0,
            queuedFrames: 0,
            outputSampleRate: outputDevice?.sampleRate ?? Double(CamMicFrameCodec.sampleRate),
            receivedPackets: receivedPackets,
            receivedPCMBytes: receivedPCMBytes,
            receivedPCMRMS: receivedPCMRMS,
            receivedPCMPeak: receivedPCMPeak,
            protocolErrors: protocolErrors,
            underrunCallbacks: value?.underruns ?? 0,
            renderContentions: value?.renderContentions ?? 0,
            lastConsumedSequence: value?.lastConsumed ?? 0
        )
    }

    private func stopResources() {
        let oldConnection = connection
        connection = nil
        oldConnection?.stateUpdateHandler = nil
        oldConnection?.cancel()
        let oldInitializationConnection = initializationConnection
        initializationConnection = nil
        oldInitializationConnection?.stateUpdateHandler = nil
        oldInitializationConnection?.cancel()
        acknowledgementTimer?.setEventHandler {}
        acknowledgementTimer?.cancel()
        acknowledgementTimer = nil
        diagnosticsTimer?.setEventHandler {}
        diagnosticsTimer?.cancel()
        diagnosticsTimer = nil
        output?.stopAndClear()
        output = nil
        outputDevice = nil
        microphoneDevice = nil
        activeSessionID = nil
        receiveSequence = nil
        decoder = CamMicFrameDecoder()
        acknowledgementInFlight = false
        lastAcknowledgementSent = 0
        receivedPackets = 0
        receivedPCMBytes = 0
        receivedPCMRMS = 0
        receivedPCMPeak = 0
        protocolErrors = 0
        activeTransport = nil
    }

    private func recordReceivedPCM(_ payload: Data) {
        let sampleCount = payload.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else {
            receivedPCMRMS = 0
            receivedPCMPeak = 0
            return
        }
        var sumSquares = 0.0
        var peak = 0.0
        for index in 0..<sampleCount {
            let low = UInt16(payload[index * 2])
            let high = UInt16(payload[index * 2 + 1]) << 8
            let sample = Double(Int16(bitPattern: low | high)) / 32768.0
            sumSquares += sample * sample
            peak = max(peak, abs(sample))
        }
        receivedPCMBytes += UInt64(payload.count)
        receivedPCMRMS = sqrt(sumSquares / Double(sampleCount))
        receivedPCMPeak = peak
    }

    private func isCurrent(_ token: UUID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generation == token
    }

    private func currentGeneration() -> UUID {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generation
    }

    private func publish(_ message: String, token: UUID) {
        eventDelivery { [weak self] in
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
        eventDelivery { [weak self] in
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

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16) |
            (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
    }

    static func encodeAcknowledgement(sessionID: Data, consumedSequence: UInt64) throws -> Data {
        try CamMicFrameCodec.encode(
            CamMicFrame(kind: .acknowledgement, sessionID: sessionID, sequence: consumedSequence)
        )
    }

#if DEBUG
    func installUSBInitializationForTesting(_ initialization: NWConnection, generation token: UUID) {
        queue.sync {
            stopResources()
            stateLock.lock()
            generation = token
            metricsUpdatePending = false
            metricsPendingToken = nil
            stateLock.unlock()
            initializationConnection = initialization
        }
    }

    func completeUSBInitializationForTesting(key: Data, generation token: UUID, initialization: NWConnection) {
        queue.sync {
            connectUSBAudio(preSharedKey: key, token: token, initialization: initialization, audioPort: 50890)
        }
    }

    func endSessionForTesting(generation token: UUID) {
        queue.sync { endSession(token: token, message: "test cancellation") }
    }

    func installUSBAudioForTesting(_ audio: NWConnection, generation token: UUID) {
        queue.sync {
            stopResources()
            stateLock.lock()
            generation = token
            metricsUpdatePending = false
            metricsPendingToken = nil
            stateLock.unlock()
            connection = audio
        }
    }

    func deliverUSBAudioStateForTesting(_ state: NWConnection.State, audio: NWConnection, generation token: UUID) {
        queue.sync { handleUSBAudioState(state, audio: audio, token: token) }
    }

    func ownsUSBInitializationForTesting(_ initialization: NWConnection) -> Bool {
        queue.sync { initializationConnection === initialization }
    }

    var audioConnectionPresentForTesting: Bool { queue.sync { connection != nil } }

    var metricsPendingGenerationForTesting: UUID? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return metricsPendingToken
    }

    var isMutedForTesting: Bool { queue.sync { isMuted } }

    func publishStatusForTesting(_ message: String, generation token: UUID) { publish(message, token: token) }
    func publishMetricsForTesting(_ value: Metrics, generation token: UUID) { publishMetrics(value, token: token) }
    func flushTransportQueueForTesting() { queue.sync {} }
#endif
}
