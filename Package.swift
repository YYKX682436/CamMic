// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CamMicMac",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "CamMicMac", targets: ["CamMicMac"])],
    targets: [
        .target(name: "CamMicShared", path: "Shared"),
        .executableTarget(name: "CamMicMac", dependencies: ["CamMicShared"], path: "MacApp"),
        .testTarget(name: "CamMicSharedTests", dependencies: ["CamMicShared"], path: "SharedTests")
    ]
)
