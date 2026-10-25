import AVFoundation
import UIKit
import XCTest
@testable import CamMic

final class RouteChangeTests: XCTestCase {
    func testBackgroundRouteNotificationStopsActiveCaptureOnMainQueue() {
        let capture = AudioCapture()
        capture.simulatedCaptureForRouteTest = true
        let controller = CaptureViewController(capture: capture)
        controller.loadViewIfNeeded() // Registers the production selector observer.

        XCTAssertTrue(capture.isCapturing)
        postFromBackground(.categoryChange)
        XCTAssertTrue(capture.isCapturing, "Startup category changes must be ignored")

        postFromBackground(.oldDeviceUnavailable)
        XCTAssertFalse(capture.isCapturing, "The real AudioCapture.stop() must have run")
        XCTAssertEqual(
            statusText(in: controller.view),
            "音频输入设备变化，采集已停止。请重新开始。"
        )

        postFromBackground(.oldDeviceUnavailable)
        XCTAssertFalse(capture.isCapturing, "A repeated notification must be harmless")
    }

    private func postFromBackground(_ reason: AVAudioSession.RouteChangeReason) {
        let processed = expectation(description: "Route notification processed on main queue")
        DispatchQueue.global(qos: .userInitiated).async {
            XCTAssertFalse(Thread.isMainThread)
            NotificationCenter.default.post(
                name: AVAudioSession.routeChangeNotification,
                object: AVAudioSession.sharedInstance(),
                userInfo: [AVAudioSessionRouteChangeReasonKey: reason.rawValue]
            )
            // The selector's main-queue work was enqueued before this sentinel.
            DispatchQueue.main.async { processed.fulfill() }
        }
        wait(for: [processed], timeout: 5)
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
