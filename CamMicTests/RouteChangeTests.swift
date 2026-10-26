import AVFoundation
import UIKit
import XCTest
@testable import CamMic

final class RouteChangeTests: XCTestCase {
    func testBackgroundAndForegroundTransitionsKeepTheSameCaptureRun() {
        let capture = FakeCapture()
        let controller = makeController(capture: capture)
        controller.loadViewIfNeeded()
        controller.setCaptureGenerationForTesting(UUID())
        let run = controller.activeCaptureRunForTesting
        XCTAssertTrue(capture.isCapturing)
        XCTAssertTrue(controller.captureIntentActiveForTesting)

        postFromBackground(UIApplication.willResignActiveNotification)
        postFromBackground(UIApplication.didEnterBackgroundNotification)
        XCTAssertTrue(capture.isCapturing, "Backgrounding and locking must not stop the microphone engine")
        XCTAssertEqual(controller.activeCaptureRunForTesting, run)
        XCTAssertEqual(capture.startCount, 1, "Backgrounding must not rebuild the converter or capture queue")

        postFromBackground(UIApplication.willEnterForegroundNotification)
        postFromBackground(UIApplication.didBecomeActiveNotification)
        XCTAssertTrue(capture.isCapturing)
        XCTAssertEqual(controller.activeCaptureRunForTesting, run)
        XCTAssertEqual(capture.startCount, 1, "Returning to the foreground must not restart capture")
        controller.stopTapped()
    }

    func testUserStopCancelsDelayedRouteRecoveryAndInterruptionResume() {
        let capture = FakeCapture()
        let controller = makeController(capture: capture)
        controller.loadViewIfNeeded()
        controller.setCaptureGenerationForTesting(UUID())
        let startsBeforeStop = capture.startCount

        controller.handleRouteChangeForTesting(reason: .oldDeviceUnavailable, fingerprint: "no-input")
        controller.stopTapped()
        controller.handleInterruptionForTesting(type: .began)
        controller.handleInterruptionForTesting(type: .ended, options: .shouldResume)
        postFromBackground(UIApplication.didEnterBackgroundNotification)
        postFromBackground(UIApplication.willEnterForegroundNotification)
        waitOnMainQueue(0.4)

        XCTAssertFalse(capture.isCapturing)
        XCTAssertFalse(controller.captureIntentActiveForTesting)
        XCTAssertEqual(capture.startCount, startsBeforeStop, "A delayed notification must not start after manual stop")
        XCTAssertEqual(controller.captureStateDescriptionForTesting, "stopped")
    }

    func testInterruptionRequiresExplicitIntentAndOnlyRestoresOnce() {
        let capture = FakeCapture()
        let controller = makeController(capture: capture)
        controller.loadViewIfNeeded()
        controller.setCaptureGenerationForTesting(UUID())
        let oldRun = controller.activeCaptureRunForTesting
        let intentWasActive = controller.captureIntentActiveForTesting

        controller.handleInterruptionForTesting(type: .began)
        controller.handleInterruptionForTesting(type: .began)
        XCTAssertFalse(capture.isCapturing)
        XCTAssertTrue(controller.captureIntentActiveForTesting)
        XCTAssertEqual(capture.stopCount, 1, "Repeated begin notifications must not stop a new generation")
        XCTAssertTrue(controller.captureStateDescriptionForTesting.hasPrefix("interrupted:"))

        controller.handleInterruptionForTesting(type: .ended, options: [])
        XCTAssertFalse(capture.isCapturing, "Without shouldResume the app must wait for the user or a later route event")
        XCTAssertEqual(capture.startCount, 1)

        controller.handleInterruptionForTesting(type: .ended, options: .shouldResume)
        XCTAssertTrue(capture.isCapturing)
        XCTAssertTrue(controller.captureIntentActiveForTesting)
        XCTAssertNotEqual(controller.activeCaptureRunForTesting, oldRun)
        XCTAssertEqual(capture.startCount, 2)
        XCTAssertEqual(controller.captureIntentActiveForTesting, intentWasActive)

        controller.handleInterruptionForTesting(type: .ended, options: .shouldResume)
        XCTAssertEqual(capture.startCount, 2, "A duplicate end notification must not start a second engine")
        controller.stopTapped()
    }

    func testRouteChangeRebuildsWithFreshFormatAndDoesNotRetryTheSameFailedRoute() {
        let capture = FakeCapture()
        let controller = makeController(capture: capture)
        controller.loadViewIfNeeded()
        controller.setCaptureGenerationForTesting(UUID())
        controller.setRouteFingerprintForTesting("built-in|44100|1")
        capture.nextInputFormat = AudioCapture.InputFormat(sampleRate: 32_000, channelCount: 2)
        capture.failNextStart = true

        controller.handleRouteChangeForTesting(reason: .oldDeviceUnavailable, fingerprint: "headset-removed|48000|0")
        XCTAssertFalse(capture.isCapturing)
        XCTAssertTrue(controller.captureIntentActiveForTesting)
        XCTAssertTrue(controller.captureStateDescriptionForTesting.hasPrefix("waiting:"))

        waitOnMainQueue(0.4)
        XCTAssertEqual(capture.startCount, 2, "The changed route gets one fresh-format start attempt")
        XCTAssertFalse(capture.isCapturing)

        controller.handleRouteChangeForTesting(reason: .routeConfigurationChange, fingerprint: "headset-removed|48000|0")
        waitOnMainQueue(0.35)
        XCTAssertEqual(capture.startCount, 2, "Repeated notifications for the same unavailable route must not busy-retry")

        let restored = expectation(description: "a new available route starts a fresh capture run")
        capture.onStart = { if capture.startCount == 3 { restored.fulfill() } }
        controller.handleRouteChangeForTesting(reason: .newDeviceAvailable, fingerprint: "built-in|48000|1")
        wait(for: [restored], timeout: 2)
        XCTAssertTrue(capture.isCapturing)
        XCTAssertEqual(capture.startCount, 3)
        XCTAssertTrue(controller.inputFormatDescriptionForTesting?.contains("32000 Hz · 2 声道") == true,
                      "The replacement converter must report the new route's actual input format")
        controller.stopTapped()
    }

    func testOldCaptureErrorCannotStopReplacementRun() {
        let capture = FakeCapture()
        let controller = makeController(capture: capture)
        controller.loadViewIfNeeded()
        controller.setCaptureGenerationForTesting(UUID())
        let oldRun = controller.activeCaptureRunForTesting!
        controller.stopTapped()

        controller.setCaptureGenerationForTesting(UUID())
        let replacement = controller.activeCaptureRunForTesting!
        capture.onCaptureError?(oldRun, CapturePCM16Pipeline.PipelineError.converterFailure)

        XCTAssertTrue(capture.isCapturing)
        XCTAssertEqual(controller.activeCaptureRunForTesting, replacement)
        XCTAssertEqual(controller.captureStateDescriptionForTesting, "capturing")
        controller.stopTapped()
    }

    private func makeController(capture: FakeCapture) -> CaptureViewController {
        CaptureViewController(capture: capture)
    }

    private func postFromBackground(_ name: Notification.Name) {
        let processed = expectation(description: "Application state notification processed on main queue")
        DispatchQueue.global(qos: .userInitiated).async {
            XCTAssertFalse(Thread.isMainThread)
            NotificationCenter.default.post(name: name, object: nil)
            DispatchQueue.main.async { processed.fulfill() }
        }
        wait(for: [processed], timeout: 5)
    }

    private func waitOnMainQueue(_ delay: TimeInterval) {
        let completed = expectation(description: "main queue recovery window elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { completed.fulfill() }
        wait(for: [completed], timeout: delay + 2)
    }
}

private final class FakeCapture: AudioCaptureControlling {
    var onAudioFrame: ((AudioCapture.CaptureRun, UInt64, Data) -> Void)?
    var onCaptureOverrun: ((AudioCapture.CaptureRun, BoundedPCMQueue.OverrunDiagnostic) -> Void)?
    var onCaptureError: ((AudioCapture.CaptureRun, Error) -> Void)?
    private(set) var isCapturing = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var deactivationCount = 0
    var failNextStart = false
    var onStart: (() -> Void)?
    var nextInputFormat = AudioCapture.InputFormat(sampleRate: 48_000, channelCount: 1)
    var levelSnapshot: (Float, Float) = (0, -80)
    var diagnosticsSnapshot: AudioCapture.DiagnosticsSnapshot? { nil }

    func start(listenerGeneration: UUID) throws -> AudioCapture.StartResult {
        startCount += 1
        if failNextStart {
            failNextStart = false
            throw FakeCaptureError.unavailable
        }
        isCapturing = true
        let result = AudioCapture.StartResult(
            run: AudioCapture.CaptureRun(listenerGeneration: listenerGeneration, generation: UUID()),
            inputFormat: nextInputFormat
        )
        onStart?()
        return result
    }

    func stop(deactivateSession: Bool) {
        if isCapturing { stopCount += 1 }
        isCapturing = false
        if deactivateSession { deactivationCount += 1 }
    }

    func deactivateAudioSession() { deactivationCount += 1 }
}

private enum FakeCaptureError: LocalizedError {
    case unavailable
    var errorDescription: String? { "fake input unavailable" }
}
