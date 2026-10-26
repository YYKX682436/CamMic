import Foundation
import Network
import UIKit
import AVFoundation
import XCTest
@testable import CamMic

final class AudioLinkServerTests: XCTestCase {
#if DEBUG
    func testUSBProbeListenerParametersBindOnlyIPv4LoopbackAtRequestedPort() throws {
        for port in [AudioLinkServer.usbInitializationPort, AudioLinkServer.usbAudioPort] {
            let parameters = AudioLinkServer.usbLoopbackParameters(port: port)
            guard case let .hostPort(host, boundPort)? = parameters.requiredLocalEndpoint else {
                XCTFail("USB probe parameters must require a concrete local host and port")
                continue
            }
            guard case let .ipv4(address) = host else {
                XCTFail("USB probe listener must bind IPv4 loopback")
                continue
            }
            XCTAssertEqual(address, .loopback)
            XCTAssertEqual(boundPort, port)

            do {
                let listener = try NWListener(using: parameters)
                listener.cancel()
            } catch {
                XCTFail("The loopback endpoint already supplies its listener port: \(error)")
            }
        }

        let audioParameters = CamMicPairing.makeNetworkParameters(
            preSharedKey: try CamMicPairing.newSessionKey(),
            identity: CamMicPairing.usbTLSPSKIdentity
        )
        audioParameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback),
            port: AudioLinkServer.usbAudioPort
        )
        do {
            let listener = try NWListener(using: audioParameters)
            listener.cancel()
        } catch {
            XCTFail("The TLS loopback endpoint already supplies its listener port: \(error)")
        }
    }

    func testUSBSessionMaterialIsGatedByExplicitCaptureAndInvalidatedOnStop() {
        let server = AudioLinkServer(eventDelivery: { _ in })
        let exerciseLifecycle = {
            do {
                let run = try server.startUSBProbe()
                XCTAssertTrue(server.usbSessionKeyPresentForTesting)
                XCTAssertFalse(server.usbInitializationActiveForTesting,
                               "The init listener stays stopped until capture startup succeeds")

                server.markUSBProbeCaptureActive(generation: run.generation)
                XCTAssertTrue(server.usbInitializationActiveForTesting)

                server.stop()
                XCTAssertFalse(server.usbSessionKeyPresentForTesting)
                XCTAssertFalse(server.usbInitializationActiveForTesting)
                XCTAssertFalse(server.listenerRunningForTesting)
            } catch {
                XCTFail("Unable to create the local-only Debug probe listeners: \(error)")
            }
        }
        if Thread.isMainThread {
            exerciseLifecycle()
        } else {
            DispatchQueue.main.sync(execute: exerciseLifecycle)
        }
    }
#endif

    func testDelayedOldListenerFailureCannotStopOrOverwriteNewCapture() {
        var scheduledDeliveries: [() -> Void] = []
        let server = AudioLinkServer(eventDelivery: { scheduledDeliveries.append($0) })
        let capture = AudioCapture()
        let controller = CaptureViewController(capture: capture, link: server)
        controller.loadViewIfNeeded()

        let oldGeneration = UUID()
        let newGeneration = UUID()
        controller.setCaptureGenerationForTesting(oldGeneration)
        server.setListenerGenerationForTesting(oldGeneration)
        server.failListenerForTesting("旧监听错误", generation: oldGeneration)
        XCTAssertEqual(scheduledDeliveries.count, 1)

        controller.setCaptureGenerationForTesting(newGeneration)
        server.setListenerGenerationForTesting(newGeneration)
        scheduledDeliveries.removeFirst()()
        controller.consumeAudioLinkEvent(AudioLinkServer.Event(
            listenerGeneration: oldGeneration,
            kind: .listenerFailure,
            message: "迟到的旧会话错误"
        ))
        XCTAssertTrue(capture.isCapturing)
        XCTAssertNotEqual(statusText(in: controller.view), "迟到的旧会话错误")

        server.failListenerForTesting("当前监听错误", generation: newGeneration)
        XCTAssertEqual(scheduledDeliveries.count, 1)
        scheduledDeliveries.removeFirst()()
        XCTAssertFalse(capture.isCapturing, "A fatal event for the active listener must stop capture")
        XCTAssertEqual(statusText(in: controller.view), "当前监听错误")
    }

    func testLateStatusFromOldConnectionCannotOverwriteReplacementSession() {
        var scheduledDeliveries: [() -> Void] = []
        let server = AudioLinkServer(eventDelivery: { scheduledDeliveries.append($0) })
        let capture = AudioCapture()
        let controller = CaptureViewController(capture: capture, link: server)
        controller.loadViewIfNeeded()

        let generation = UUID()
        controller.setCaptureGenerationForTesting(generation)
        server.setListenerGenerationForTesting(generation)
        controller.consumeAudioLinkEvent(AudioLinkServer.Event(
            listenerGeneration: generation,
            kind: .status,
            message: "新会话当前状态"
        ))

        let oldConnectionEpoch = server.statusEpochForTesting
        server.publishStatusForTesting("旧连接迟到状态", generation: generation, statusEpoch: oldConnectionEpoch)
        let newConnectionEpoch = server.advanceStatusEpochForTesting()
        scheduledDeliveries.removeFirst()()
        XCTAssertEqual(statusText(in: controller.view), "新会话当前状态")

        server.publishStatusForTesting("替换连接当前状态", generation: generation, statusEpoch: newConnectionEpoch)
        scheduledDeliveries.removeFirst()()
        XCTAssertEqual(statusText(in: controller.view), "替换连接当前状态")
        XCTAssertTrue(capture.isCapturing)
    }

    func testUnrecoverablePCMConversionFailureStillStopsCapture() {
        let capture = AudioCapture()
        let server = AudioLinkServer(eventDelivery: { _ in })
        let controller = CaptureViewController(capture: capture, link: server)
        controller.loadViewIfNeeded()
        let generation = UUID()
        controller.setCaptureGenerationForTesting(generation)

        capture.onCaptureError?(generation, CapturePCM16Pipeline.PipelineError.converterFailure)

        XCTAssertFalse(capture.isCapturing)
        XCTAssertEqual(statusText(in: controller.view), "音频转换失败：AVAudioConverter 无法完成 PCM 转换。")
    }

    func testUnrecoverableCaptureBufferFaultStillStopsCapture() {
        let capture = AudioCapture()
        let server = AudioLinkServer(eventDelivery: { _ in })
        let controller = CaptureViewController(capture: capture, link: server)
        controller.loadViewIfNeeded()
        let generation = UUID()
        controller.setCaptureGenerationForTesting(generation)
        server.setListenerGenerationForTesting(generation)

        capture.onCaptureOverrun?(generation, BoundedPCMQueue.OverrunDiagnostic(
            reason: .inputFrameExceedsSlot(actual: 16_385, maximum: 16_384)
        ))

        XCTAssertFalse(capture.isCapturing)
        XCTAssertEqual(server.listenerRunningForTesting, false)
        XCTAssertEqual(statusText(in: controller.view), "音频输入队列无法安全接收数据，已断开并清空旧数据。\n诊断：单个系统音频块有 16385 帧，缓冲槽上限为 16384 帧。 请重新开始。")
    }

    func testNormalEOFReceiveCompletionClearsHandlerAndPendingAudioWithoutACKWaiters() {
        let cancellations = CancellationCounter()
        let server = AudioLinkServer(
            eventDelivery: { _ in },
            cancelConnection: { connection in
                cancellations.increment()
                connection.cancel()
            }
        )
        let listenerGeneration = UUID()
        let connectionToken = UUID()
        let connection = makeConnection()
        connection.stateUpdateHandler = { _ in }
        let window = CamMicAcknowledgementWindow(maximumInFlight: 1)
        XCTAssertEqual(window.tryAcquireNextSequence(), 1)
        server.installConnectionForTesting(
            connection,
            listenerGeneration: listenerGeneration,
            connectionToken: connectionToken,
            window: window
        )
        server.sendAudio(
            Data(repeating: 0, count: CamMicFrameCodec.audioPayloadLength),
            listenerGeneration: listenerGeneration,
            capturedAtNanoseconds: 1
        )
        server.flushTransportQueueForTesting()
        XCTAssertEqual(server.metricsSnapshot.pendingPackets, 1)

        server.receiveEOFForTesting(token: connectionToken)

        XCTAssertNil(connection.stateUpdateHandler)
        XCTAssertEqual(cancellations.value, 1)
        XCTAssertNil(server.activeConnectionTokenForTesting)
        XCTAssertEqual(server.metricsSnapshot.pendingPackets, 0)
        XCTAssertNil(window.tryAcquireNextSequence(), "Teardown must stop new sequence allocation")
        server.receiveEOFForTesting(token: connectionToken)
        XCTAssertEqual(cancellations.value, 1, "Repeated EOF cleanup must be harmless")
    }

    func testASecondMacConnectionIsRejectedWhileTheCurrentSessionIsActive() {
        let server = AudioLinkServer(eventDelivery: { _ in })
        let listenerGeneration = UUID()
        let activeToken = UUID()
        let activeConnection = makeConnection()
        activeConnection.stateUpdateHandler = { _ in }
        server.installConnectionForTesting(
            activeConnection,
            listenerGeneration: listenerGeneration,
            connectionToken: activeToken,
            window: CamMicAcknowledgementWindow(maximumInFlight: 8)
        )

        let rejectedConnection = makeConnection()
        server.acceptForTesting(rejectedConnection, listenerGeneration: listenerGeneration)

        XCTAssertEqual(server.activeConnectionTokenForTesting, activeToken)
        XCTAssertFalse(server.isActiveConnectionForTesting(rejectedConnection))
        server.stop()
    }

    func testLateOldConnectionCallbackCannotClearReplacementAndReceiveErrorUsesCleanup() {
        let cancellations = CancellationCounter()
        let server = AudioLinkServer(
            eventDelivery: { _ in },
            cancelConnection: { connection in
                cancellations.increment()
                connection.cancel()
            }
        )
        let listenerGeneration = UUID()
        let oldToken = UUID()
        let oldConnection = makeConnection()
        oldConnection.stateUpdateHandler = { _ in }
        server.installConnectionForTesting(
            oldConnection,
            listenerGeneration: listenerGeneration,
            connectionToken: oldToken,
            window: CamMicAcknowledgementWindow(maximumInFlight: 2)
        )
        server.receiveEOFForTesting(token: oldToken)

        let newToken = UUID()
        let newConnection = makeConnection()
        newConnection.stateUpdateHandler = { _ in }
        let newWindow = CamMicAcknowledgementWindow(maximumInFlight: 2)
        server.installConnectionForTesting(
            newConnection,
            listenerGeneration: listenerGeneration,
            connectionToken: newToken,
            window: newWindow
        )

        server.receiveEOFForTesting(token: oldToken)
        XCTAssertEqual(cancellations.value, 1)
        XCTAssertEqual(server.activeConnectionTokenForTesting, newToken)
        XCTAssertNotNil(newConnection.stateUpdateHandler)
        XCTAssertEqual(newWindow.tryAcquireNextSequence(), 1, "The late callback must not stop the new ACK window")

        server.failConnectionForTesting(token: newToken)
        XCTAssertEqual(cancellations.value, 2)
        XCTAssertNil(newConnection.stateUpdateHandler)
        XCTAssertNil(server.activeConnectionTokenForTesting)
    }

    func testReconnectClearsOldAudioAndStartsNewSessionAtLiveTimestamp() {
        let server = AudioLinkServer(eventDelivery: { _ in })
        let listenerGeneration = UUID()
        let oldToken = UUID()
        let oldConnection = makeConnection()
        oldConnection.stateUpdateHandler = { _ in }
        let oldWindow = CamMicAcknowledgementWindow(maximumInFlight: 1)
        _ = oldWindow.tryAcquireNextSequence()
        server.installConnectionForTesting(
            oldConnection, listenerGeneration: listenerGeneration,
            connectionToken: oldToken, window: oldWindow
        )
        server.sendAudio(
            Data(repeating: 0x11, count: CamMicFrameCodec.audioPayloadLength),
            listenerGeneration: listenerGeneration,
            capturedAtNanoseconds: 10
        )
        server.flushTransportQueueForTesting()
        XCTAssertEqual(server.metricsSnapshot.pendingPackets, 1)

        server.receiveEOFForTesting(token: oldToken)
        XCTAssertEqual(server.metricsSnapshot.pendingPackets, 0)
        server.sendAudio(
            Data(repeating: 0x12, count: CamMicFrameCodec.audioPayloadLength),
            listenerGeneration: listenerGeneration,
            capturedAtNanoseconds: 20
        )
        XCTAssertEqual(server.metricsSnapshot.droppedPackets, 2,
                       "Disconnect clears one queued packet and counts live audio discarded before reconnection")

        let newToken = UUID()
        let newSessionID = Data(repeating: 0x66, count: 16)
        let newConnection = makeConnection()
        newConnection.stateUpdateHandler = { _ in }
        server.installConnectionForTesting(
            newConnection, listenerGeneration: listenerGeneration,
            connectionToken: newToken, window: CamMicAcknowledgementWindow(maximumInFlight: 8),
            sessionID: newSessionID, readyAtNanoseconds: 100
        )
        server.receiveEOFForTesting(token: oldToken)

        var sentFrames: [CamMicFrame] = []
        server.onAudioFrameSentForTesting = { sentFrames.append($0) }
        server.sendAudio(
            Data(repeating: 0x22, count: CamMicFrameCodec.audioPayloadLength),
            listenerGeneration: listenerGeneration,
            capturedAtNanoseconds: 99
        )
        XCTAssertEqual(server.metricsSnapshot.pendingPackets, 0,
                       "Frames captured before the replacement session became ready must be discarded")
        server.sendAudio(
            Data(repeating: 0x33, count: CamMicFrameCodec.audioPayloadLength),
            listenerGeneration: listenerGeneration,
            capturedAtNanoseconds: 100
        )
        server.flushTransportQueueForTesting()

        XCTAssertEqual(server.activeConnectionTokenForTesting, newToken)
        XCTAssertEqual(sentFrames.map(\.sequence), [1])
        XCTAssertEqual(sentFrames.first?.sessionID, newSessionID)
        XCTAssertEqual(sentFrames.first?.payload.first, 0x33)
        XCTAssertEqual(server.metricsSnapshot.droppedPackets, 3,
                       "The pre-ready callback is counted and never replayed in the replacement session")
        server.stop()
    }

    func testExplicitStopUsesConnectionTeardownAndCanBeRepeated() {
        let cancellations = CancellationCounter()
        let server = AudioLinkServer(
            eventDelivery: { _ in },
            cancelConnection: { connection in
                cancellations.increment()
                connection.cancel()
            }
        )
        let connection = makeConnection()
        connection.stateUpdateHandler = { _ in }
        let window = CamMicAcknowledgementWindow(maximumInFlight: 1)
        XCTAssertEqual(window.tryAcquireNextSequence(), 1)
        let generation = UUID()
        server.installConnectionForTesting(
            connection,
            listenerGeneration: generation,
            connectionToken: UUID(),
            window: window
        )
        server.sendAudio(
            Data(repeating: 0, count: CamMicFrameCodec.audioPayloadLength),
            listenerGeneration: generation,
            capturedAtNanoseconds: 1
        )
        server.flushTransportQueueForTesting()
        XCTAssertEqual(server.metricsSnapshot.pendingPackets, 1)

        server.stop()
        server.stop()
        server.flushTransportQueueForTesting()

        XCTAssertNil(connection.stateUpdateHandler)
        XCTAssertEqual(cancellations.value, 1)
        XCTAssertNil(window.tryAcquireNextSequence())
        XCTAssertEqual(server.metricsSnapshot.pendingPackets, 0)
    }

    func testSaturatedACKWindowDoesNotBlockAudioConversionCaller() {
        let server = AudioLinkServer(eventDelivery: { _ in })
        let listenerGeneration = UUID()
        let connectionToken = UUID()
        let window = CamMicAcknowledgementWindow(maximumInFlight: 8)
        for sequence in 1...8 {
            XCTAssertEqual(window.tryAcquireNextSequence(), UInt64(sequence))
        }
        server.installConnectionForTesting(
            makeConnection(),
            listenerGeneration: listenerGeneration,
            connectionToken: connectionToken,
            window: window
        )

        let returned = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            server.sendAudio(
                Data(repeating: 0, count: CamMicFrameCodec.audioPayloadLength),
                listenerGeneration: listenerGeneration,
                capturedAtNanoseconds: 1
            )
            returned.signal()
        }
        let returnedWithoutWaitingForACK = returned.wait(timeout: .now() + .milliseconds(100)) == .success

        // Stop also cancels a queued drain so the regression leaves no work behind.
        server.stop()
        if !returnedWithoutWaitingForACK {
            XCTAssertEqual(returned.wait(timeout: .now() + 1), .success,
                           "Stopping the listener must release a legacy blocked sender")
        }
        XCTAssertTrue(returnedWithoutWaitingForACK, "ACK backpressure must never occupy the PCM conversion worker")
    }

    func testHalfSecondACKDelayBoundsPendingQueueAndPreservesSequenceAfterRecovery() {
        let server = AudioLinkServer(eventDelivery: { _ in })
        let listenerGeneration = UUID()
        let connectionToken = UUID()
        let window = CamMicAcknowledgementWindow(maximumInFlight: 8)
        for sequence in 1...8 { XCTAssertEqual(window.tryAcquireNextSequence(), UInt64(sequence)) }
        server.installConnectionForTesting(
            makeConnection(), listenerGeneration: listenerGeneration,
            connectionToken: connectionToken, window: window
        )
        server.setAcknowledgementProgressForTesting(1_000_000_000)
        var sentFrames: [CamMicFrame] = []
        server.onAudioFrameSentForTesting = { sentFrames.append($0) }

        // 25 packets represent 500 ms at the 20 ms transport frame interval.
        for index in 0..<25 {
            server.sendAudio(
                Data(repeating: UInt8(index), count: CamMicFrameCodec.audioPayloadLength),
                listenerGeneration: listenerGeneration,
                capturedAtNanoseconds: UInt64(index + 1)
            )
        }
        server.flushTransportQueueForTesting()
        XCTAssertEqual(server.metricsSnapshot.pendingPackets, 8)
        XCTAssertEqual(server.metricsSnapshot.pendingHighWaterMark, 8)
        XCTAssertEqual(server.metricsSnapshot.droppedPackets, 17)
        XCTAssertTrue(sentFrames.isEmpty, "A full window must not reserve or emit a sequence")
        server.checkAcknowledgementStallForTesting(token: connectionToken, nowNanoseconds: 1_500_000_000)
        XCTAssertEqual(server.activeConnectionTokenForTesting, connectionToken,
                       "A 500 ms delayed ACK remains within the existing stall budget")

        server.acknowledgeForTesting(8, token: connectionToken)
        server.flushTransportQueueForTesting()
        XCTAssertEqual(sentFrames.map(\.sequence), Array(9...16).map(UInt64.init))
        XCTAssertEqual(sentFrames.map { $0.payload.first ?? 0 }, Array(17..<25).map(UInt8.init))
        server.stop()
    }

    func testAudioFramesSendWithoutDropsWhenACKWindowHasCapacity() {
        let server = AudioLinkServer(eventDelivery: { _ in })
        let generation = UUID()
        let token = UUID()
        let connection = makeConnection()
        let window = CamMicAcknowledgementWindow(maximumInFlight: 8)
        server.installConnectionForTesting(
            connection, listenerGeneration: generation, connectionToken: token, window: window
        )
        var sentFrames: [CamMicFrame] = []
        server.onAudioFrameSentForTesting = { sentFrames.append($0) }

        for index in 0..<5 {
            server.sendAudio(
                Data(repeating: UInt8(index), count: CamMicFrameCodec.audioPayloadLength),
                listenerGeneration: generation,
                capturedAtNanoseconds: UInt64(index + 1)
            )
        }
        server.flushTransportQueueForTesting()

        XCTAssertEqual(sentFrames.map(\.sequence), Array(1...5).map(UInt64.init))
        XCTAssertEqual(sentFrames.map { $0.payload.first ?? 0 }, Array(0..<5).map(UInt8.init))
        XCTAssertEqual(server.metricsSnapshot.droppedPackets, 0)
        XCTAssertEqual(server.metricsSnapshot.pendingPackets, 0)
        XCTAssertEqual(server.metricsSnapshot.inFlight, 5)
        server.stop()
    }

    func testOnePointFiveSecondAndMissingACKStallsDropOnlyConnection() {
        for elapsedNanoseconds: UInt64 in [1_500_000_000, 5_000_000_000] {
            let server = AudioLinkServer(eventDelivery: { action in action() })
            let capture = AudioCapture()
            let controller = CaptureViewController(capture: capture, link: server)
            controller.loadViewIfNeeded()
            let generation = UUID()
            controller.setCaptureGenerationForTesting(generation)
            server.setListenerGenerationForTesting(generation)

            let token = UUID()
            let connection = makeConnection()
            connection.stateUpdateHandler = { _ in }
            let window = CamMicAcknowledgementWindow(maximumInFlight: 8)
            for _ in 1...8 { _ = window.tryAcquireNextSequence() }
            server.installConnectionForTesting(
                connection, listenerGeneration: generation, connectionToken: token, window: window
            )
            server.setAcknowledgementProgressForTesting(1_000_000_000)
            server.sendAudio(
                Data(repeating: 0x7F, count: CamMicFrameCodec.audioPayloadLength),
                listenerGeneration: generation,
                capturedAtNanoseconds: 1
            )
            server.flushTransportQueueForTesting()
            server.checkAcknowledgementStallForTesting(
                token: token,
                nowNanoseconds: 1_000_000_000 + elapsedNanoseconds
            )

            XCTAssertNil(server.activeConnectionTokenForTesting)
            XCTAssertTrue(server.listenerRunningForTesting)
            XCTAssertTrue(capture.isCapturing, "An ACK stall must preserve user-started microphone capture")
            XCTAssertEqual(server.metricsSnapshot.pendingPackets, 0, "Disconnect must clear stale pending audio")
            server.stop()
        }
    }

    func testScheduledACKWatchdogDropsConnectionAndLeavesCaptureRunning() {
        let connectionCancelled = DispatchSemaphore(value: 0)
        let server = AudioLinkServer(
            eventDelivery: { _ in },
            cancelConnection: { connection in
                connection.cancel()
                connectionCancelled.signal()
            }
        )
        let listenerGeneration = UUID()
        let token = UUID()
        let window = CamMicAcknowledgementWindow(maximumInFlight: 8)
        for _ in 1...8 { _ = window.tryAcquireNextSequence() }
        let connection = makeConnection()
        server.installConnectionForTesting(
            connection, listenerGeneration: listenerGeneration,
            connectionToken: token, window: window
        )
        server.sendAudio(
            Data(repeating: 0x55, count: CamMicFrameCodec.audioPayloadLength),
            listenerGeneration: listenerGeneration,
            capturedAtNanoseconds: 1
        )
        server.flushTransportQueueForTesting()
        let capture = AudioCapture()
        capture.simulatedCaptureForRouteTest = true
        let now = DispatchTime.now().uptimeNanoseconds
        server.setAcknowledgementProgressForTesting(
            now - AudioLinkServer.acknowledgementStallTimeoutNanoseconds - 1
        )
        server.startAcknowledgementWatchdogForTesting(token: token)

        XCTAssertEqual(connectionCancelled.wait(timeout: .now() + 1), .success)
        XCTAssertNil(server.activeConnectionTokenForTesting)
        XCTAssertTrue(server.listenerRunningForTesting)
        XCTAssertTrue(capture.isCapturing)
        XCTAssertEqual(server.metricsSnapshot.pendingPackets, 0)
        server.stop()
    }

    func testContinuous4410FrameCallbacksKeepConvertingWhileACKWindowIsFull() throws {
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 1,
            interleaved: false
        )!
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
        let pipeline = try CapturePCM16Pipeline(
            converter: XCTUnwrap(AVAudioConverter(from: inputFormat, to: outputFormat)),
            inputFormat: inputFormat,
            outputFormat: outputFormat
        )
        let queue = BoundedPCMQueue(
            format: inputFormat,
            slotCount: 12,
            maximumFrames: 16_384,
            maximumBufferedFrames: 13_230
        )
        defer { queue.finish() }

        let listenerGeneration = UUID()
        let window = CamMicAcknowledgementWindow(maximumInFlight: 8)
        for _ in 1...8 { _ = window.tryAcquireNextSequence() }
        let server = AudioLinkServer(eventDelivery: { _ in })
        server.installConnectionForTesting(
            makeConnection(), listenerGeneration: listenerGeneration,
            connectionToken: UUID(), window: window
        )

        let source = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 4_410)!
        source.frameLength = 4_410
        let sourceSamples = source.floatChannelData!.pointee
        for index in 0..<4_410 { sourceSamples[index] = 0.1 }
        let workerReady = DispatchSemaphore(value: 0)
        let processed = DispatchSemaphore(value: 0)
        let workerFinished = DispatchSemaphore(value: 0)
        let workerError = StringBox()
        let callbackCount = 50

        DispatchQueue(label: "CamMicTests.44100-conversion", qos: .userInitiated).async {
            workerReady.signal()
            defer { workerFinished.signal() }
            for _ in 0..<callbackCount {
                guard let item = queue.take() else { return }
                let frames: [CapturePCM16Pipeline.AudioFrame]
                do {
                    frames = try pipeline.append(item.buffer, capturedAtNanoseconds: item.capturedAtNanoseconds)
                } catch {
                    queue.release(item.index)
                    workerError.store(error.localizedDescription)
                    processed.signal()
                    return
                }
                queue.release(item.index)
                for frame in frames {
                    server.sendAudio(
                        frame.pcm,
                        listenerGeneration: listenerGeneration,
                        capturedAtNanoseconds: frame.capturedAtNanoseconds
                    )
                }
                processed.signal()
            }
        }

        XCTAssertEqual(workerReady.wait(timeout: .now() + 1), .success)
        var acceptedCallbacks = 0
        for index in 0..<callbackCount {
            let result = queue.copyFromSystemBuffer(
                source,
                capturedAtNanoseconds: DispatchTime.now().uptimeNanoseconds
            )
            guard result == .copied else {
                XCTFail("The 44.1 kHz capture callback should remain accepted at block \(index)")
                break
            }
            guard processed.wait(timeout: .now() + 1) == .success else {
                XCTFail("A full ACK window stalled PCM conversion at block \(index)")
                break
            }
            acceptedCallbacks += 1
            if let error = workerError.load() {
                XCTFail("PCM conversion failed: \(error)")
                break
            }
        }

        queue.finish()
        XCTAssertEqual(workerFinished.wait(timeout: .now() + 1), .success)
        server.flushTransportQueueForTesting()
        XCTAssertEqual(acceptedCallbacks, callbackCount)
        XCTAssertGreaterThan(pipeline.convertedSampleCount, 230_000)
        XCTAssertEqual(queue.metricsSnapshot.bufferedFrames, 0)
        XCTAssertEqual(queue.droppedFramesForTesting, 0, "Normal callback cadence must not drop capture audio")
        XCTAssertLessThanOrEqual(queue.metricsSnapshot.maximumObservedBufferedFrames, 13_230)
        XCTAssertEqual(server.metricsSnapshot.pendingPackets, 8)
        XCTAssertLessThanOrEqual(server.metricsSnapshot.pendingHighWaterMark, 8)
        XCTAssertGreaterThan(server.metricsSnapshot.droppedPackets, 0,
                             "Transport pressure should discard stale network audio instead of stalling capture")
        XCTAssertEqual(server.metricsSnapshot.acknowledgementWindowFullEvents, 1)
        server.stop()
    }

    private func makeConnection() -> NWConnection {
        NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: 50888)!, using: .tcp)
    }

    private func statusText(in view: UIView) -> String? {
        if view.accessibilityIdentifier == "capture.status" {
            return (view as? UILabel)?.text
        }
        for child in view.subviews {
            if let text = statusText(in: child) { return text }
        }
        return nil
    }
}
private final class CancellationCounter {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private final class StringBox {
    private let lock = NSLock()
    private var value: String?

    func store(_ value: String) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func load() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
