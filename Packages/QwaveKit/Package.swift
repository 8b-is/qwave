// swift-tools-version:6.0
import PackageDescription

// Per-target Swift language mode. tools-version 6.0 defaults targets to
// language mode 6, so every not-yet-migrated target is explicitly pinned to
// `.v5` and modules are flipped to `.v6` one at a time (see docs and the
// structural-foundations work). This lets each module's strict-concurrency
// migration land as its own reviewable commit instead of one big-bang flip.
let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]
let v6: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "QwaveKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        // Umbrella product linked by the Qwave app target.
        .library(
            name: "QwaveKit",
            targets: [
                "BrowserCore", "Shields", "FeatureFlags", "VPNKit", "Persistence", "QwaveSupport", "WebExtensions",
                "URLIdentity", "MemoryWave",
            ]
        ),
        // Slim product linked by the PacketTunnel system extension.
        .library(
            name: "QwaveTunnelKit",
            targets: ["VPNKit", "QwaveSupport"]
        ),
    ],
    dependencies: [
        // WHATWG URL parser — canonical host identity for policy decisions
        // (matches WebKit; Foundation URL.host does not). Pinned exactly:
        // 0.x semver, see research/collections-foundation/weburl.md.
        .package(url: "https://github.com/karwa/swift-url", exact: "0.4.2"),
        // Structured logging front-end for QwaveLog; the os_log backend lives
        // in QwaveSupport. 1.7+ moves to a new LogEvent handler API, so stay
        // on the 1.6.x line deliberately.
        .package(url: "https://github.com/apple/swift-log.git", .upToNextMinor(from: "1.6.4")),
        // Test-only: golden files for the uBO → content-blocker compiler.
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.9.0"),
        // OrderedDictionary for TabManager: ordered + unique + O(1) keyed
        // lookup is exactly the tab strip's shape.
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.6.0"),
    ],
    targets: [
        // MIGRATED to Swift 6 language mode.
        .target(
            name: "QwaveSupport",
            dependencies: [
                .product(name: "Logging", package: "swift-log")
            ],
            swiftSettings: v6
        ),
        // Canonical (WHATWG) host identity. Kept out of QwaveTunnelKit so the
        // tunnel extension doesn't carry a URL parser it never uses.
        .target(
            name: "URLIdentity",
            dependencies: [
                .product(name: "WebURL", package: "swift-url"),
                .product(name: "WebURLFoundationExtras", package: "swift-url"),
            ],
            swiftSettings: v5
        ),
        // MIGRATED to Swift 6 language mode.
        .target(name: "Persistence", dependencies: ["QwaveSupport"], swiftSettings: v6),
        .target(
            name: "Shields",
            dependencies: ["QwaveSupport", "Persistence", "URLIdentity"],
            resources: [
                .process("Resources")
            ],
            swiftSettings: v5
        ),
        .target(name: "FeatureFlags", dependencies: ["QwaveSupport"], swiftSettings: v5),
        .target(
            name: "BrowserCore",
            dependencies: [
                "QwaveSupport", "Persistence", "Shields", "FeatureFlags", "URLIdentity",
                .product(name: "OrderedCollections", package: "swift-collections"),
            ],
            resources: [
                .process("Resources")
            ],
            swiftSettings: v6
        ),
        // Post-quantum cryptography: Keccak, ML-KEM-768, Classic McEliece 348864,
        // and the hybrid construction used by the Stage B VPN negotiator.
        .target(name: "PostQuantum", swiftSettings: v5),
        .target(name: "VPNKit", dependencies: ["QwaveSupport", "PostQuantum"], swiftSettings: v5),
        // WebExtensions Manifest V3 engine: browser.* bridge, storage, popups.
        .target(name: "WebExtensions", dependencies: ["QwaveSupport"], swiftSettings: v5),
        // MEM8 wave substrate: Cognitive/Nexus provenance, 79-byte WaveInt,
        // encrypted container-scoped store, AI-agnostic inference providers.
        .target(name: "MemoryWave", dependencies: ["QwaveSupport", "Persistence"], swiftSettings: v5),

        .testTarget(
            name: "QwaveSupportTests",
            dependencies: [
                "QwaveSupport",
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: v5
        ),
        .testTarget(name: "URLIdentityTests", dependencies: ["URLIdentity"], swiftSettings: v5),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence"], swiftSettings: v5),
        .testTarget(
            name: "ShieldsTests",
            dependencies: [
                "Shields",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            swiftSettings: v5
        ),
        .testTarget(name: "FeatureFlagsTests", dependencies: ["FeatureFlags"], swiftSettings: v5),
        .testTarget(name: "BrowserCoreTests", dependencies: ["BrowserCore", "URLIdentity"], swiftSettings: v5),
        .testTarget(
            name: "PostQuantumTests", dependencies: ["PostQuantum"], resources: [.process("Fixtures")],
            swiftSettings: v5),
        .testTarget(name: "WebExtensionsTests", dependencies: ["WebExtensions"], swiftSettings: v5),
        .testTarget(
            name: "VPNKitTests",
            dependencies: ["VPNKit"],
            resources: [
                .process("Fixtures")
            ],
            swiftSettings: v5
        ),
        .testTarget(
            name: "MemoryWaveTests", dependencies: ["MemoryWave", "QwaveSupport", "Persistence"], swiftSettings: v5),
        // Egress regression gate: enforces the committed Category-A host
        // allowlist against every module that can make Qwave's own requests.
        .testTarget(
            name: "EgressGuardTests",
            dependencies: ["QwaveSupport", "Shields", "VPNKit", "MemoryWave"],
            swiftSettings: v5
        ),
    ]
)
