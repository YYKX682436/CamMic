// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CamMicMac",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "CamMicMac", targets: ["CamMicMac"])],
    targets: [
        .target(name: "CamMicShared", path: "Shared"),
        .target(name: "CamMicMacCore", dependencies: ["CamMicShared"], path: "MacCore"),
        .executableTarget(name: "CamMicMac", dependencies: ["CamMicShared", "CamMicMacCore"], path: "MacApp"),
        .testTarget(name: "CamMicSharedTests", dependencies: ["CamMicShared"], path: "SharedTests"),
        .testTarget(name: "CamMicMacCoreTests", dependencies: ["CamMicMacCore"], path: "MacCoreTests"),
        .testTarget(name: "CamMicMacTransportTests", dependencies: ["CamMicMac", "CamMicShared"], path: "MacTransportTests")
    ]
)
