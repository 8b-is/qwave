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
        .target(
            name: "QwaveSupport",
            dependencies: [
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        // Canonical (WHATWG) host identity. Kept out of QwaveTunnelKit so the
        // tunnel extension doesn't carry a URL parser it never uses.
        .target(
            name: "URLIdentity",
            dependencies: [
                .product(name: "WebURL", package: "swift-url"),
                .product(name: "WebURLFoundationExtras", package: "swift-url"),
            ]
        ),
        .target(name: "Persistence", dependencies: ["QwaveSupport"]),
        .target(
            name: "Shields",
            dependencies: ["QwaveSupport", "Persistence", "URLIdentity"],
            resources: [
                .process("Resources")
            ]
        ),
        .target(name: "FeatureFlags", dependencies: ["QwaveSupport"]),
        .target(
            name: "BrowserCore",
            dependencies: [
                "QwaveSupport", "Persistence", "Shields", "FeatureFlags", "URLIdentity",
                .product(name: "OrderedCollections", package: "swift-collections"),
            ],
            resources: [
                .process("Resources")
            ]
        ),
        // Post-quantum cryptography: Keccak, ML-KEM-768, Classic McEliece 348864,
        // and the hybrid construction used by the Stage B VPN negotiator.
        .target(name: "PostQuantum"),
        .target(name: "VPNKit", dependencies: ["QwaveSupport", "PostQuantum"]),
        // WebExtensions Manifest V3 engine: browser.* bridge, storage, popups.
        .target(name: "WebExtensions", dependencies: ["QwaveSupport"]),
        // MEM8 wave substrate: Cognitive/Nexus provenance, 79-byte WaveInt,
        // encrypted container-scoped store, AI-agnostic inference providers.
        .target(name: "MemoryWave", dependencies: ["QwaveSupport", "Persistence"]),

        .testTarget(
            name: "QwaveSupportTests",
            dependencies: [
                "QwaveSupport",
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(name: "URLIdentityTests", dependencies: ["URLIdentity"]),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence"]),
        .testTarget(
            name: "ShieldsTests",
            dependencies: [
                "Shields",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ]
        ),
        .testTarget(name: "FeatureFlagsTests", dependencies: ["FeatureFlags"]),
        .testTarget(name: "BrowserCoreTests", dependencies: ["BrowserCore", "URLIdentity"]),
        .testTarget(name: "PostQuantumTests", dependencies: ["PostQuantum"], resources: [.process("Fixtures")]),
        .testTarget(name: "WebExtensionsTests", dependencies: ["WebExtensions"]),
        .testTarget(
            name: "VPNKitTests",
            dependencies: ["VPNKit"],
            resources: [
                .process("Fixtures")
            ]
        ),
        .testTarget(name: "MemoryWaveTests", dependencies: ["MemoryWave", "QwaveSupport", "Persistence"]),
        // Egress regression gate: enforces the committed Category-A host
        // allowlist against every module that can make Qwave's own requests.
        .testTarget(
            name: "EgressGuardTests",
            dependencies: ["QwaveSupport", "Shields", "VPNKit", "MemoryWave"]
        ),
    ]
)
