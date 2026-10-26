import XCTest
import Network
@testable import CamMicMac

final class USBForwarderTests: XCTestCase {
    func testInProcessForwarderUsesAnEphemeralLoopbackPortAndReleasesIt() throws {
        let device = CamMicUSBDevice(udid: "00000000-00000000000000000000000000000000")
        let forwarder = try LibUSBMuxForwarder(device: device, devicePort: 50889)
        let localPort = forwarder.localPort
        XCTAssertNotEqual(localPort, 0)

        forwarder.stop()
        let releasedPort = NWEndpoint.Port(rawValue: localPort)!
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: releasedPort)
        let listener = try NWListener(using: parameters)
        let becameReady = expectation(description: "the in-process listener released its local port")
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: becameReady.fulfill()
            case .failed(let error):
                XCTFail("The CamMic-owned USB endpoint leaked after stop: \(error)")
                becameReady.fulfill()
            default: break
            }
        }
        listener.start(queue: DispatchQueue(label: "CamMicMacTransportTests.usb-port-release"))
        wait(for: [becameReady], timeout: 3)
        listener.cancel()
    }
}
