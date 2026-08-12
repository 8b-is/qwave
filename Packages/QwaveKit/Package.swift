// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "QwaveKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        // Umbrella product linked by the Qwave app target.
        .library(
            name: "QwaveKit",
            targets: ["BrowserCore", "Shields", "FeatureFlags", "VPNKit", "Persistence", "QwaveSupport"]
        ),
        // Slim product linked by the PacketTunnel system extension.
        .library(
            name: "QwaveTunnelKit",
            targets: ["VPNKit", "QwaveSupport"]
        ),
    ],
    targets: [
        .target(name: "QwaveSupport"),
        .target(name: "Persistence", dependencies: ["QwaveSupport"]),
        .target(
            name: "Shields",
            dependencies: ["QwaveSupport", "Persistence"],
            resources: [
                .process("Resources")
            ]
        ),
        .target(name: "FeatureFlags", dependencies: ["QwaveSupport"]),
        .target(
            name: "BrowserCore",
            dependencies: ["QwaveSupport", "Persistence", "Shields", "FeatureFlags"]
        ),
        .target(name: "VPNKit", dependencies: ["QwaveSupport"]),

        .testTarget(name: "QwaveSupportTests", dependencies: ["QwaveSupport"]),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence"]),
        .testTarget(name: "ShieldsTests", dependencies: ["Shields"]),
        .testTarget(name: "FeatureFlagsTests", dependencies: ["FeatureFlags"]),
        .testTarget(name: "BrowserCoreTests", dependencies: ["BrowserCore"]),
        .testTarget(
            name: "VPNKitTests",
            dependencies: ["VPNKit"],
            resources: [
                .process("Fixtures")
            ]
        ),
    ]
)
