// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MemoPilot",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "MemoPilotCore", targets: ["MemoPilotCore"]),
        .executable(name: "MemoPilot", targets: ["MemoPilot"])
    ],
    targets: [
        .target(
            name: "MemoPilotCore"
        ),
        .executableTarget(
            name: "MemoPilot",
            dependencies: ["MemoPilotCore"]
        ),
        .testTarget(
            name: "MemoPilotTests",
            dependencies: ["MemoPilotCore"]
        )
    ]
)
