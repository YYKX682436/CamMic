import CamMicUSBMux
import Foundation

struct CamMicUSBDevice: Hashable, Identifiable {
    let udid: String

    var id: String { udid }
    var displayName: String {
        let suffix = String(udid.suffix(4))
        return "iPhone ··\(suffix)"
    }
}

enum CamMicUSBTransportError: LocalizedError {
    case discovery(Int32)
    case forwarding(Int32)

    var errorDescription: String? {
        switch self {
        case .discovery:
            return "无法读取 USB 设备列表。请解锁 iPhone 并确认已信任这台 Mac。"
        case .forwarding:
            return "无法建立 USB 连接。请重新插拔数据线并确认 iPhone 已启动 CamMic 采音。"
        }
    }
}

protocol CamMicUSBDeviceDiscovering: AnyObject {
    var onDeviceEvent: ((Int32, CamMicUSBDevice) -> Void)? { get set }
    func start() throws -> [CamMicUSBDevice]
    func stop()
}

final class LibUSBMuxDeviceDiscovery: CamMicUSBDeviceDiscovering {
    var onDeviceEvent: ((Int32, CamMicUSBDevice) -> Void)?
    private var subscription: OpaquePointer?
    private var retainedContext: UnsafeMutableRawPointer?

    func start() throws -> [CamMicUSBDevice] {
        guard subscription == nil else { return try Self.snapshot() }
        let retained = Unmanaged.passRetained(self).toOpaque()
        retainedContext = retained
        var errorCode: Int32 = 0
        let newSubscription = cammic_usbmux_subscribe(Self.eventCallback, retained, &errorCode)
        guard let newSubscription else {
            retainedContext = nil
            Unmanaged<LibUSBMuxDeviceDiscovery>.fromOpaque(retained).release()
            throw CamMicUSBTransportError.discovery(errorCode)
        }
        subscription = newSubscription
        return try Self.snapshot()
    }

    func stop() {
        guard let subscription = subscription else { return }
        self.subscription = nil
        cammic_usbmux_unsubscribe(subscription)
        if let retainedContext = retainedContext {
            self.retainedContext = nil
            Unmanaged<LibUSBMuxDeviceDiscovery>.fromOpaque(retainedContext).release()
        }
        onDeviceEvent = nil
    }

    deinit { stop() }

    private static func snapshot() throws -> [CamMicUSBDevice] {
        let collector = DeviceListCollector()
        let context = Unmanaged.passUnretained(collector).toOpaque()
        let result = cammic_usbmux_copy_usb_devices(Self.deviceListCallback, context)
        guard result >= 0 else { throw CamMicUSBTransportError.discovery(result) }
        return collector.devices
    }

    private static let eventCallback: CamMicUSBMuxEventCallback = { eventType, rawID, context in
        guard let context, let rawID else { return }
        let owner = Unmanaged<LibUSBMuxDeviceDiscovery>.fromOpaque(context).takeUnretainedValue()
        owner.onDeviceEvent?(eventType, CamMicUSBDevice(udid: String(cString: rawID)))
    }

    private static let deviceListCallback: CamMicUSBMuxDeviceCallback = { rawID, context in
        guard let rawID, let context else { return }
        let collector = Unmanaged<DeviceListCollector>.fromOpaque(context).takeUnretainedValue()
        collector.append(String(cString: rawID))
    }
}

private final class DeviceListCollector {
    private(set) var devices: [CamMicUSBDevice] = []
    func append(_ udid: String) { devices.append(CamMicUSBDevice(udid: udid)) }
}

protocol CamMicUSBForwarding: AnyObject {
    var localPort: UInt16 { get }
    func stop()
}

protocol CamMicUSBForwarderCreating {
    func make(device: CamMicUSBDevice, devicePort: UInt16) throws -> CamMicUSBForwarding
}

struct LibUSBMuxForwarderFactory: CamMicUSBForwarderCreating {
    func make(device: CamMicUSBDevice, devicePort: UInt16) throws -> CamMicUSBForwarding {
        try LibUSBMuxForwarder(device: device, devicePort: devicePort)
    }
}

final class LibUSBMuxForwarder: CamMicUSBForwarding {
    let localPort: UInt16
    private var handle: OpaquePointer?

    init(device: CamMicUSBDevice, devicePort: UInt16) throws {
        var port: UInt16 = 0
        var errorCode: Int32 = 0
        let newHandle = device.udid.withCString {
            cammic_usbmux_forwarder_start($0, devicePort, &port, &errorCode)
        }
        guard let newHandle else { throw CamMicUSBTransportError.forwarding(errorCode) }
        handle = newHandle
        localPort = port
    }

    func stop() {
        guard let handle = handle else { return }
        self.handle = nil
        cammic_usbmux_forwarder_stop(handle)
    }

    deinit { stop() }
}
