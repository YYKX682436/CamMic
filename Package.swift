// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CamMicMac",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "CamMicMac", targets: ["CamMicMac"])],
    targets: [
        .systemLibrary(
            name: "CLibusbmuxd",
            path: "MacUSBMux/CLibusbmuxd",
            pkgConfig: "libusbmuxd-2.0"
        ),
        .target(name: "CamMicUSBMux", dependencies: ["CLibusbmuxd"], path: "MacUSBMux", exclude: ["CLibusbmuxd"], publicHeadersPath: "include"),
        .target(name: "CamMicShared", path: "Shared"),
        .target(name: "CamMicMacCore", dependencies: ["CamMicShared"], path: "MacCore"),
        .executableTarget(name: "CamMicMac", dependencies: ["CamMicShared", "CamMicMacCore", "CamMicUSBMux"], path: "MacApp"),
        .testTarget(name: "CamMicSharedTests", dependencies: ["CamMicShared"], path: "SharedTests"),
        .testTarget(name: "CamMicMacCoreTests", dependencies: ["CamMicMacCore"], path: "MacCoreTests"),
        .testTarget(name: "CamMicMacTransportTests", dependencies: ["CamMicMac", "CamMicShared", "CamMicUSBMux"], path: "MacTransportTests")
    ]
)
