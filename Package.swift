// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ClaudeIsland",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "ClaudeIsland"),
        .testTarget(name: "ClaudeIslandTests", dependencies: ["ClaudeIsland"]),
    ]
)
