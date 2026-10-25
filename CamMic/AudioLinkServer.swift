import Foundation
import Network
import Dispatch

/// iPhone is the only listener. A fresh 8-digit code configures TLS-PSK for each capture run.
final class AudioLinkServer {
    static let port = NWEndpoint.Port(rawValue: CamMicFrameCodec.tcpPort)!
    static let acknowledgementStallTimeoutNanoseconds: UInt64 = 1_250_000_000
    private static let pendingPacketLimit = 8

    /// Decoder state belongs to one connection and is touched only by its
    /// Network.framework receive queue. A cancelled connection cannot mutate the
    /// decoder used by a replacement session.
    private final class ReceiveDecoder {
        var value = CamMicFrameDecoder()
    }

    struct ListenerRun {
        let pairingCode: String
        let generation: UUID
    }

    struct Event {
        enum Kind { case status, listenerFailure }

        let listenerGeneration: UUID
        let kind: Kind
        let message: String
    }

    var onEvent: ((Event) -> Void)?

    var metricsSnapshot: (
        acknowledgements: UInt64,
        averageRTTMilliseconds: Double,
        maximumRTTMilliseconds: Double,
        inFlight: UInt64,
        pendingPackets: Int,
        pendingHighWaterMark: Int,
        droppedPackets: UInt64,
        acknowledgementWindowFullEvents: UInt64,
        acknowledgementStallMilliseconds: Double
    ) {
        stateLock.lock()
        let activeWindow = window
        let pendingSnapshot = pendingAudio?.snapshot
        let inFlight = activeWindow?.inFlightCount ?? 0
        let now = DispatchTime.now().uptimeNanoseconds
        let stallMilliseconds: Double
        if let lastProgress = lastAcknowledgementProgressNanoseconds,
           inFlight > 0, now >= lastProgress {
            stallMilliseconds = Double(now - lastProgress) / 1_000_000
        } else {
            stallMilliseconds = 0
        }
        let values = (
            acknowledgementCount,
            averageRTTMilliseconds,
            maximumRTTMilliseconds,
            inFlight,
            pendingSnapshot?.queuedPackets ?? 0,
            pendingSnapshot?.highWaterMark ?? 0,
            droppedAudioPackets,
            acknowledgementWindowFullEvents,
            stallMilliseconds
        )
        stateLock.unlock()
        return (
            values.0,
            values.1,
            values.2,
            values.3,
            values.4,
            values.5,
            values.6,
            values.7,
            values.8
        )
    }

    private let queue = DispatchQueue(label: "com.yykx682436.CamMic.network-server", qos: .userInitiated)
    private let stateLock = NSLock()
    private var listener: NWListener?
    private var connection: NWConnection?
    private var sessionID: Data?
    private var window: CamMicAcknowledgementWindow?
    private var pendingAudio: CamMicPendingAudioBuffer?
    private var sendDrainScheduled = false
    private var acknowledgementWindowBlocked = false
    private var running = false
    private var ready = false
    private var readyAtNanoseconds: UInt64?
    private var generation = UUID()
    private var statusRevision = UUID()
    private var statusEpoch = UUID()
    private var activeConnectionToken: UUID?
    private var sentAtNanoseconds: [UInt64: UInt64] = [:]
    private var highestAcknowledgedSequence: UInt64 = 0
    private var lastAcknowledgementProgressNanoseconds: UInt64?
    private var acknowledgementCount: UInt64 = 0
    private var averageRTTMilliseconds = 0.0
    private var maximumRTTMilliseconds = 0.0
    private var droppedAudioPackets: UInt64 = 0
    private var acknowledgementWindowFullEvents: UInt64 = 0
    private let eventDelivery: (@escaping () -> Void) -> Void
    private let cancelConnection: (NWConnection) -> Void

#if DEBUG
    var onAudioFrameSentForTesting: ((CamMicFrame) -> Void)?
#endif

    init(
        eventDelivery: @escaping (@escaping () -> Void) -> Void = { action in
            DispatchQueue.main.async(execute: action)
        },
        cancelConnection: @escaping (NWConnection) -> Void = { $0.cancel() }
    ) {
        self.eventDelivery = eventDelivery
        self.cancelConnection = cancelConnection
    }

    func start() throws -> ListenerRun {
        precondition(Thread.isMainThread)
        stop()
        let newCode = CamMicPairing.newCode()
        let newListener = try NWListener(using: CamMicPairing.makeNetworkParameters(pairingCode: newCode), on: Self.port)
        let token = UUID()
        let listenerStatusEpoch = UUID()
        stateLock.lock()
        generation = token
        statusEpoch = listenerStatusEpoch
        listener = newListener
        running = true
        readyAtNanoseconds = nil
        droppedAudioPackets = 0
        acknowledgementWindowFullEvents = 0
        stateLock.unlock()

        newListener.stateUpdateHandler = { [weak self] state in
            guard let self = self, self.isListenerCurrent(token) else { return }
            switch state {
            case .ready:
                self.publishStatus(
                    "正在监听 iPhone TCP/TLS 端口 50888；等待 Mac 输入配对码连接。",
                    generation: token,
                    statusEpoch: listenerStatusEpoch
                )
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
        let oldConnection = detachConnectionLocked()
        listener = nil
        acknowledgementCount = 0
        averageRTTMilliseconds = 0
        maximumRTTMilliseconds = 0
        running = false
        generation = UUID()
        statusRevision = UUID()
        statusEpoch = UUID()
        stateLock.unlock()

        releaseConnection(oldConnection)
        oldListener?.stateUpdateHandler = nil
        oldListener?.newConnectionHandler = nil
        oldListener?.cancel()
    }

    /// Called by the PCM conversion worker. It performs only a bounded enqueue;
    /// ACK waits and Network.framework sends run on the server queue.
    func sendAudio(_ pcm: Data, listenerGeneration: UUID, capturedAtNanoseconds: UInt64) {
        guard pcm.count == CamMicFrameCodec.audioPayloadLength else { return }
        stateLock.lock()
        guard running, generation == listenerGeneration else {
            stateLock.unlock()
            return
        }
        guard ready, let readyAt = readyAtNanoseconds,
              capturedAtNanoseconds >= readyAt,
              let token = activeConnectionToken, let pendingAudio = pendingAudio else {
            droppedAudioPackets += 1
            stateLock.unlock()
            return
        }
        droppedAudioPackets += pendingAudio.enqueue(
            capturedAtNanoseconds: capturedAtNanoseconds,
            payload: pcm
        )
        if !acknowledgementWindowBlocked { scheduleTransportDrainLocked(token: token) }
        stateLock.unlock()
    }

    /// Schedules at most one small network-queue task regardless of how many
    /// converted frames arrive while that queue is busy.
    private func scheduleTransportDrainLocked(token: UUID) {
        guard !sendDrainScheduled, !acknowledgementWindowBlocked else { return }
        sendDrainScheduled = true
        queue.async { [weak self] in self?.drainPendingAudio(connectionToken: token) }
    }

    private func drainPendingAudio(connectionToken token: UUID) {
        while true {
            stateLock.lock()
            guard running, ready, activeConnectionToken == token,
                  let connection = connection, let sessionID = sessionID,
                  let window = window, let pendingAudio = pendingAudio else {
                if activeConnectionToken == token { sendDrainScheduled = false }
                stateLock.unlock()
                return
            }
            guard pendingAudio.snapshot.queuedPackets > 0 else {
                sendDrainScheduled = false
                stateLock.unlock()
                return
            }
            guard let sequence = window.tryAcquireNextSequence() else {
                if !acknowledgementWindowBlocked { acknowledgementWindowFullEvents += 1 }
                acknowledgementWindowBlocked = true
                sendDrainScheduled = false
                stateLock.unlock()
                return
            }
            guard let packet = pendingAudio.dequeue() else {
                // The state lock serializes enqueue/clear against this dequeue.
                // A missing packet here means the session cannot be sent safely.
                sendDrainScheduled = false
                stateLock.unlock()
                failConnection(token: token, message: "音频发送队列状态无效，连接已重置。")
                return
            }
            let now = DispatchTime.now().uptimeNanoseconds
            if lastAcknowledgementProgressNanoseconds == nil {
                lastAcknowledgementProgressNanoseconds = now
            }
            sentAtNanoseconds[sequence] = now
            stateLock.unlock()

            let frame = CamMicFrame(kind: .audio, sessionID: sessionID, sequence: sequence, payload: packet.payload)
            do {
                let data = try CamMicFrameCodec.encode(frame)
                guard isCurrent(token, connection: connection) else { return }
#if DEBUG
                if let onAudioFrameSentForTesting = onAudioFrameSentForTesting {
                    onAudioFrameSentForTesting(frame)
                    continue
                }
#endif
                connection.send(content: data, completion: .contentProcessed { [weak self] error in
                    guard let error = error, let self = self else { return }
                    self.failConnection(token: token, message: "音频发送失败：\(error.localizedDescription)")
                })
            } catch {
                failConnection(token: token, message: "音频帧编码失败，连接已重置。")
                return
            }
        }
    }

    private func scheduleAcknowledgementWatchdog(listenerGeneration: UUID, connectionToken: UUID) {
        queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            guard let self = self else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            self.checkAcknowledgementStall(
                listenerGeneration: listenerGeneration,
                connectionToken: connectionToken,
                nowNanoseconds: now
            )
            if self.isCurrent(connectionToken) {
                self.scheduleAcknowledgementWatchdog(
                    listenerGeneration: listenerGeneration,
                    connectionToken: connectionToken
                )
            }
        }
    }

    private func checkAcknowledgementStall(
        listenerGeneration: UUID,
        connectionToken: UUID,
        nowNanoseconds: UInt64
    ) {
        stateLock.lock()
        let stalled: Bool
        if running, generation == listenerGeneration, activeConnectionToken == connectionToken,
           (window?.inFlightCount ?? 0) > 0,
           let lastProgress = lastAcknowledgementProgressNanoseconds,
           nowNanoseconds >= lastProgress {
            stalled = nowNanoseconds - lastProgress >= Self.acknowledgementStallTimeoutNanoseconds
        } else {
            stalled = false
        }
        stateLock.unlock()
        if stalled {
            failConnection(
                token: connectionToken,
                message: "Mac 确认停滞超过 1.25 秒；旧音频已清空并断开连接，采音仍在继续，可重新连接。"
            )
        }
    }

    private func acknowledge(_ sequence: UInt64, connectionToken token: UUID) throws {
        stateLock.lock()
        let activeWindow = activeConnectionToken == token ? window : nil
        stateLock.unlock()
        guard let activeWindow = activeWindow else { throw CamMicProtocolError.wrongSession }
        try activeWindow.acknowledge(sequence)

        let now = DispatchTime.now().uptimeNanoseconds
        stateLock.lock()
        guard activeConnectionToken == token else {
            stateLock.unlock()
            return
        }
        if sequence > highestAcknowledgedSequence {
            highestAcknowledgedSequence = sequence
            lastAcknowledgementProgressNanoseconds = activeWindow.inFlightCount > 0 ? now : nil
            acknowledgementWindowBlocked = false
        }
        if let sentAt = sentAtNanoseconds[sequence], now >= sentAt {
            let duration = Double(now - sentAt) / 1_000_000
            acknowledgementCount += 1
            averageRTTMilliseconds += (duration - averageRTTMilliseconds) / Double(acknowledgementCount)
            maximumRTTMilliseconds = max(maximumRTTMilliseconds, duration)
        }
        let completedSequences = sentAtNanoseconds.keys.filter { $0 <= sequence }
        for oldSequence in completedSequences {
            sentAtNanoseconds.removeValue(forKey: oldSequence)
        }
        if pendingAudio?.snapshot.queuedPackets ?? 0 > 0 {
            scheduleTransportDrainLocked(token: token)
        }
        stateLock.unlock()
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
        let connectionStatusEpoch = UUID()
        connection = newConnection
        statusEpoch = connectionStatusEpoch
        activeConnectionToken = connectionToken
        sessionID = newSessionID
        window = newWindow
        pendingAudio = CamMicPendingAudioBuffer(maximumPackets: Self.pendingPacketLimit)
        sendDrainScheduled = false
        acknowledgementWindowBlocked = false
        sentAtNanoseconds.removeAll(keepingCapacity: true)
        highestAcknowledgedSequence = 0
        lastAcknowledgementProgressNanoseconds = nil
        acknowledgementCount = 0
        averageRTTMilliseconds = 0
        maximumRTTMilliseconds = 0
        ready = false
        readyAtNanoseconds = nil
        let receiveDecoder = ReceiveDecoder()
        stateLock.unlock()

        publishStatus(
            "Mac 已连接，正在检查配对和音频格式…",
            generation: token,
            statusEpoch: connectionStatusEpoch
        )
        newConnection.stateUpdateHandler = { [weak self] state in
            guard let self = self, self.isCurrent(connectionToken, connection: newConnection) else { return }
            switch state {
            case .ready:
                self.sendHello(connection: newConnection, sessionID: newSessionID, token: connectionToken)
                self.receiveNext(
                    connection: newConnection,
                    sessionID: newSessionID,
                    token: connectionToken,
                    listenerGeneration: token,
                    decoder: receiveDecoder,
                    statusEpoch: connectionStatusEpoch
                )
            case .failed(let error):
                self.failConnection(token: connectionToken, message: "Mac 连接失败：\(error.localizedDescription)")
            case .cancelled:
                self.connectionEnded(token: connectionToken, message: "Mac 已断开；等待重新连接。")
            default:
                break
            }
        }
        newConnection.start(queue: queue)
        scheduleAcknowledgementWatchdog(listenerGeneration: token, connectionToken: connectionToken)
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

    private func receiveNext(
        connection: NWConnection,
        sessionID: Data,
        token: UUID,
        listenerGeneration: UUID,
        decoder: ReceiveDecoder,
        statusEpoch: UUID
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
            guard let self = self else { return }
            self.handleReceiveCompletion(
                data: data,
                complete: complete,
                error: error,
                connection: connection,
                sessionID: sessionID,
                token: token,
                listenerGeneration: listenerGeneration,
                decoder: decoder,
                statusEpoch: statusEpoch
            )
        }
    }

    private func handleReceiveCompletion(
        data: Data?,
        complete: Bool,
        error: NWError?,
        connection: NWConnection,
        sessionID: Data,
        token: UUID,
        listenerGeneration: UUID,
        decoder: ReceiveDecoder,
        statusEpoch: UUID
    ) {
        guard isCurrent(token, connection: connection) else { return }
        if let data = data, !data.isEmpty {
            do {
                let frames = try decoder.value.append(data)
                for frame in frames {
                    try process(
                        frame,
                        expectedSessionID: sessionID,
                        connection: connection,
                        token: token,
                        listenerGeneration: listenerGeneration,
                        statusEpoch: statusEpoch
                    )
                }
            } catch {
                failConnection(token: token, message: "握手或确认帧无效，连接已关闭。")
                return
            }
        }
        if let error = error {
            failConnection(token: token, message: "连接接收失败：\(error.localizedDescription)")
        } else if complete {
            connectionEnded(token: token, message: "Mac 已断开；等待重新连接。")
        } else {
            receiveNext(
                connection: connection,
                sessionID: sessionID,
                token: token,
                listenerGeneration: listenerGeneration,
                decoder: decoder,
                statusEpoch: statusEpoch
            )
        }
    }

    private func process(
        _ frame: CamMicFrame,
        expectedSessionID: Data,
        connection: NWConnection,
        token: UUID,
        listenerGeneration: UUID,
        statusEpoch: UUID
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
            publishStatus(
                "Mac 已配对并就绪；正在持续发送 48 kHz 单声道音频。",
                generation: listenerGeneration,
                statusEpoch: statusEpoch
            )
        } else if frame.kind == .acknowledgement {
            guard frame.sequence > 0 else { throw CamMicProtocolError.invalidSequence }
            guard isCurrent(token, connection: connection) else { throw CamMicProtocolError.wrongSession }
            try acknowledge(frame.sequence, connectionToken: token)
        } else {
            throw CamMicProtocolError.invalidSequence
        }
    }

    private func failListener(token: UUID, error: NWError) {
        finishListener(token: token, message: "无法监听本地端口：\(error.localizedDescription)")
    }

    private func finishListener(token: UUID, message: String) {
        stateLock.lock()
        guard generation == token else { stateLock.unlock(); return }
        running = false
        let failureStatusEpoch = UUID()
        statusEpoch = failureStatusEpoch
        let oldListener = listener
        listener = nil
        let oldConnection = detachConnectionLocked()
        stateLock.unlock()
        releaseConnection(oldConnection)
        oldListener?.stateUpdateHandler = nil
        oldListener?.newConnectionHandler = nil
        oldListener?.cancel()
        publishFailure(message, generation: token, statusEpoch: failureStatusEpoch)
    }

    private func failConnection(token: UUID, message: String) {
        finishConnection(token: token, message: message)
    }

    private func connectionEnded(token: UUID, message: String) {
        finishConnection(token: token, message: message)
    }

    private func finishConnection(token: UUID, message: String) {
        stateLock.lock()
        guard activeConnectionToken == token else { stateLock.unlock(); return }
        let oldConnection = detachConnectionLocked()
        let stillListening = running
        let listenerGeneration = generation
        let disconnectedStatusEpoch = UUID()
        statusEpoch = disconnectedStatusEpoch
        stateLock.unlock()
        releaseConnection(oldConnection)
        publishStatus(
            stillListening ? message : "采音已停止。",
            generation: listenerGeneration,
            statusEpoch: disconnectedStatusEpoch
        )
    }

    /// Must be called while stateLock is held. Clearing identity before releasing
    /// resources makes cancellation callbacks from this connection harmless.
    private func detachConnectionLocked() -> (
        connection: NWConnection?,
        window: CamMicAcknowledgementWindow?,
        pendingAudio: CamMicPendingAudioBuffer?
    ) {
        let discardedPackets = pendingAudio?.clear() ?? 0
        droppedAudioPackets += UInt64(discardedPackets)
        let old = (connection, window, pendingAudio)
        connection = nil
        window = nil
        pendingAudio = nil
        activeConnectionToken = nil
        sendDrainScheduled = false
        acknowledgementWindowBlocked = false
        sentAtNanoseconds.removeAll(keepingCapacity: false)
        highestAcknowledgedSequence = 0
        lastAcknowledgementProgressNanoseconds = nil
        sessionID = nil
        ready = false
        readyAtNanoseconds = nil
        return old
    }

    private func releaseConnection(_ resources: (
        connection: NWConnection?,
        window: CamMicAcknowledgementWindow?,
        pendingAudio: CamMicPendingAudioBuffer?
    )) {
        resources.window?.stop()
        _ = resources.pendingAudio?.clear()
        if let connection = resources.connection {
            connection.stateUpdateHandler = nil
            cancelConnection(connection)
        }
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

    private func isCurrent(_ connectionToken: UUID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running && activeConnectionToken == connectionToken
    }

    private func publishStatus(_ message: String, generation: UUID, statusEpoch: UUID) {
        publish(Event(listenerGeneration: generation, kind: .status, message: message), statusEpoch: statusEpoch)
    }

    private func publishFailure(_ message: String, generation: UUID, statusEpoch: UUID) {
        publish(Event(listenerGeneration: generation, kind: .listenerFailure, message: message), statusEpoch: statusEpoch)
    }

    private func publish(_ event: Event, statusEpoch: UUID) {
        let revision = UUID()
        stateLock.lock()
        guard generation == event.listenerGeneration, self.statusEpoch == statusEpoch else {
            stateLock.unlock()
            return
        }
        statusRevision = revision
        stateLock.unlock()
        eventDelivery { [weak self] in
            guard let self = self else { return }
            self.stateLock.lock()
            let isCurrent = self.generation == event.listenerGeneration &&
                self.statusEpoch == statusEpoch && self.statusRevision == revision
            self.stateLock.unlock()
            guard isCurrent else { return }
            precondition(Thread.isMainThread)
            self.onEvent?(event)
        }
    }

#if DEBUG
    func setListenerGenerationForTesting(_ token: UUID) {
        stateLock.lock()
        generation = token
        statusEpoch = UUID()
        running = true
        stateLock.unlock()
    }

    func failListenerForTesting(_ message: String, generation: UUID) {
        finishListener(token: generation, message: message)
    }

    var statusEpochForTesting: UUID {
        stateLock.lock()
        defer { stateLock.unlock() }
        return statusEpoch
    }

    func advanceStatusEpochForTesting() -> UUID {
        stateLock.lock()
        statusEpoch = UUID()
        let current = statusEpoch
        stateLock.unlock()
        return current
    }

    func publishStatusForTesting(_ message: String, generation: UUID, statusEpoch: UUID) {
        publishStatus(message, generation: generation, statusEpoch: statusEpoch)
    }

    func installConnectionForTesting(
        _ connection: NWConnection,
        listenerGeneration: UUID,
        connectionToken: UUID,
        window: CamMicAcknowledgementWindow,
        sessionID testSessionID: Data = Data(repeating: 0x5A, count: 16),
        readyAtNanoseconds testReadyAtNanoseconds: UInt64 = 0
    ) {
        precondition(testSessionID.count == 16)
        stateLock.lock()
        generation = listenerGeneration
        statusEpoch = UUID()
        running = true
        self.connection = connection
        activeConnectionToken = connectionToken
        self.window = window
        pendingAudio = CamMicPendingAudioBuffer(maximumPackets: Self.pendingPacketLimit)
        sendDrainScheduled = false
        acknowledgementWindowBlocked = false
        sessionID = testSessionID
        ready = true
        readyAtNanoseconds = testReadyAtNanoseconds
        highestAcknowledgedSequence = 0
        lastAcknowledgementProgressNanoseconds = nil
        sentAtNanoseconds.removeAll(keepingCapacity: true)
        stateLock.unlock()
    }

    func receiveEOFForTesting(token: UUID) {
        stateLock.lock()
        let currentConnection = activeConnectionToken == token ? connection : nil
        let currentGeneration = generation
        let currentStatusEpoch = statusEpoch
        stateLock.unlock()
        guard let currentConnection = currentConnection else { return }
        handleReceiveCompletion(
            data: nil,
            complete: true,
            error: nil,
            connection: currentConnection,
            sessionID: Data(repeating: 0x5A, count: 16),
            token: token,
            listenerGeneration: currentGeneration,
            decoder: ReceiveDecoder(),
            statusEpoch: currentStatusEpoch
        )
    }

    func failConnectionForTesting(token: UUID) {
        failConnection(token: token, message: "连接接收失败：测试错误")
    }

    func acknowledgeForTesting(_ sequence: UInt64, token: UUID) {
        queue.sync { try? acknowledge(sequence, connectionToken: token) }
    }

    func checkAcknowledgementStallForTesting(token: UUID, nowNanoseconds: UInt64) {
        stateLock.lock()
        let listenerGeneration = generation
        stateLock.unlock()
        checkAcknowledgementStall(
            listenerGeneration: listenerGeneration,
            connectionToken: token,
            nowNanoseconds: nowNanoseconds
        )
    }

    func setAcknowledgementProgressForTesting(_ nanoseconds: UInt64) {
        stateLock.lock()
        lastAcknowledgementProgressNanoseconds = nanoseconds
        stateLock.unlock()
    }

    func startAcknowledgementWatchdogForTesting(token: UUID) {
        stateLock.lock()
        let listenerGeneration = generation
        stateLock.unlock()
        scheduleAcknowledgementWatchdog(listenerGeneration: listenerGeneration, connectionToken: token)
    }

    func flushTransportQueueForTesting() {
        queue.sync {}
    }

    var listenerRunningForTesting: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    var activeConnectionTokenForTesting: UUID? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activeConnectionToken
    }
#endif

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
