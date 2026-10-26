import XCTest
import Darwin
@testable import CamMicMac

final class USBForwarderTests: XCTestCase {
    func testInProcessForwarderUsesAnEphemeralLoopbackPortAndReleasesIt() throws {
        let device = CamMicUSBDevice(udid: "00000000-00000000000000000000000000000000")
        let forwarder = try LibUSBMuxForwarder(device: device, devicePort: 50889)
        let localPort = forwarder.localPort
        XCTAssertNotEqual(localPort, 0)

        forwarder.stop()
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = localPort.bigEndian
        address.sin_addr = in_addr(s_addr: in_addr_t(0x7f000001).bigEndian)
        let bindResult = withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bindResult, 0, "CamMic-owned USB loopback port must be released after stop")
    }
}
