// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MagicTrack",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "MTBridge"),
        .target(name: "MagicTrackCore"),
        .executableTarget(name: "MagicTrack", dependencies: ["MTBridge", "MagicTrackCore"]),
        .testTarget(name: "MagicTrackCoreTests", dependencies: ["MagicTrackCore"]),
    ]
)
