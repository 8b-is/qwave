// swift-tools-version:6.2
import PackageDescription

// The Swift 6 language mode turns complete concurrency checking on by itself,
// so an explicit `-strict-concurrency=complete` adds nothing (verified: the
// same diagnostics fire without it, and an explicit `=minimal` cannot weaken
// them). Dropping it also drops `unsafeFlags`, which bars a package from being
// consumed as a versioned dependency and is rejected in some build contexts.
let swift6: [SwiftSetting] = [
    .swiftLanguageMode(.v6)
]

let package = Package(
    name: "QwaveKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        // Umbrella product linked by the Qwave app target.
        .library(
            name: "QwaveKit",
            targets: [
                "BrowserCore", "Shields", "FeatureFlags", "VPNKit", "Persistence", "QwaveSupport", "WebExtensions",
                "URLIdentity", "MemoryWave", "Summarize", "QwaveUI",
            ]
        ),
        // Slim product linked by the PacketTunnel system extension.
        .library(
            name: "QwaveTunnelKit",
            targets: ["VPNKit", "QwaveSupport"]
        ),
        // Slim product linked by BOTH the app and the AutoFill Credential
        // Provider extension. Deliberately crypto-free (Foundation + Security
        // only) so the extension never links VPNKit / the ML-KEM stack.
        .library(
            name: "WebCredentials",
            targets: ["WebCredentials"]
        ),
        // Read-only MCP surface. Deliberately NOT part of the QwaveKit umbrella
        // product: the MCP SDK links EventSource (an SSE/URLSession client) on
        // Apple platforms, and the browser must not gain that code just because
        // an out-of-process tool wants it. Only `qwave-mcp` links this.
        .library(
            name: "MCPSurface",
            targets: ["MCPSurface"]
        ),
        .executable(
            name: "qwave-mcp",
            targets: ["QwaveMCP"]
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
        // Model Context Protocol reference SDK. Pinned EXACTLY, not by range:
        // this is a 0.x package whose minor bumps are breaking (0.12 renamed
        // Tool.Content cases), and it is the parse surface for input arriving
        // from another process — a floating pin would let that surface change
        // under us without review. Its platform floor is macOS 13 / iOS 16,
        // below Qwave's 14 / 17, so it fits; verified by building.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", exact: "0.12.1"),
    ],
    targets: [
        // MIGRATED to Swift 6 language mode.
        .target(
            name: "QwaveSupport",
            dependencies: [
                .product(name: "Logging", package: "swift-log")
            ],
            swiftSettings: swift6
        ),
        // Canonical (WHATWG) host identity. Kept out of QwaveTunnelKit so the
        // tunnel extension doesn't carry a URL parser it never uses.
        .target(
            name: "URLIdentity",
            dependencies: [
                .product(name: "WebURL", package: "swift-url"),
                .product(name: "WebURLFoundationExtras", package: "swift-url"),
            ],
            swiftSettings: swift6
        ),
        .target(name: "Persistence", dependencies: ["QwaveSupport"], swiftSettings: swift6),
        .target(
            name: "Shields",
            dependencies: ["QwaveSupport", "Persistence", "URLIdentity"],
            resources: [
                .process("Resources")
            ],
            swiftSettings: swift6
        ),
        .target(name: "FeatureFlags", dependencies: ["QwaveSupport"], swiftSettings: swift6),
        // Website-login + passkey value types and keychain store. No crypto, no
        // VPN, no other QwaveKit module — see Sources/WebCredentials.
        .target(name: "WebCredentials", swiftSettings: swift6),
        .target(
            name: "BrowserCore",
            dependencies: [
                "QwaveSupport", "Persistence", "Shields", "FeatureFlags", "URLIdentity",
                .product(name: "OrderedCollections", package: "swift-collections"),
            ],
            resources: [
                .process("Resources")
            ],
            swiftSettings: swift6
        ),
        // Post-quantum cryptography: Keccak, ML-KEM-768, and the hybrid
        // construction used by the Stage B VPN negotiator.
        .target(name: "PostQuantum", swiftSettings: swift6),
        .target(name: "VPNKit", dependencies: ["QwaveSupport", "PostQuantum"], swiftSettings: swift6),
        // WebExtensions Manifest V3 engine: browser.* bridge, storage, popups.
        .target(name: "WebExtensions", dependencies: ["QwaveSupport"], swiftSettings: swift6),
        // MEM8 wave substrate: Cognitive/Nexus provenance, 79-byte WaveInt,
        // encrypted container-scoped store, AI-agnostic inference providers.
        .target(name: "MemoryWave", dependencies: ["QwaveSupport", "Persistence"], swiftSettings: swift6),
        // On-device page summarisation via Apple's FoundationModels. Concrete
        // and small on purpose: the SDK's real extension point is
        // SystemLanguageModel.Adapter asset packaging, not a provider protocol
        // (see research/02-on-device-ai/foundation-models-probe). The only
        // FoundationModels touchpoint is SummarizeSession behind
        // canImport/available; everything else is pure and testable anywhere.
        .target(
            name: "Summarize",
            dependencies: ["BrowserCore", "QwaveSupport"],
            resources: [
                .process("Resources")
            ],
            swiftSettings: swift6
        ),
        .target(
            name: "QwaveUI",
            dependencies: [
                "BrowserCore",
                "Shields",
            ],
            swiftSettings: swift6
        ),
        // Read-only MCP server surface: tool definitions and handlers over the
        // stores Persistence already writes to disk. Depends on Persistence and
        // nothing else of Qwave's — in particular NOT on MemoryWave, so the
        // sealed memory bodies are unreachable from here by construction.
        .target(
            name: "MCPSurface",
            dependencies: [
                "Persistence",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            swiftSettings: swift6
        ),
        // The stdio binary itself. Thin on purpose: everything worth testing
        // lives in MCPSurface.
        .executableTarget(
            name: "QwaveMCP",
            dependencies: [
                "MCPSurface",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            swiftSettings: swift6
        ),

        .testTarget(
            name: "QwaveSupportTests",
            dependencies: [
                "QwaveSupport",
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: swift6
        ),
        .testTarget(name: "URLIdentityTests", dependencies: ["URLIdentity"], swiftSettings: swift6),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence"], swiftSettings: swift6),
        .testTarget(
            name: "ShieldsTests",
            dependencies: [
                "Shields",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            resources: [
                .process("__Snapshots__")
            ],
            swiftSettings: swift6
        ),
        .testTarget(name: "FeatureFlagsTests", dependencies: ["FeatureFlags"], swiftSettings: swift6),
        .testTarget(name: "WebCredentialsTests", dependencies: ["WebCredentials"], swiftSettings: swift6),
        .testTarget(
            // MemoryWave: `ArticleExtractor.userScript` is a third reader of the
            // `qwave-source` block that `InternalPages` writes, so its round trip
            // is checked against the real embedding (issue #138).
            name: "BrowserCoreTests", dependencies: ["BrowserCore", "URLIdentity", "MemoryWave"],
            swiftSettings: swift6),
        .testTarget(
            name: "PostQuantumTests", dependencies: ["PostQuantum"], resources: [.process("Fixtures")],
            swiftSettings: swift6),
        .testTarget(name: "WebExtensionsTests", dependencies: ["WebExtensions"], swiftSettings: swift6),
        .testTarget(name: "SummarizeTests", dependencies: ["Summarize", "BrowserCore"], swiftSettings: swift6),
        .testTarget(
            name: "VPNKitTests",
            dependencies: ["VPNKit"],
            resources: [
                .process("Fixtures")
            ],
            swiftSettings: swift6
        ),
        .testTarget(
            name: "MemoryWaveTests", dependencies: ["MemoryWave", "QwaveSupport", "Persistence"], swiftSettings: swift6),
        // Egress regression gate: enforces the committed Category-A host
        // allowlist against every module that can make Qwave's own requests.
        .testTarget(
            name: "MCPSurfaceTests",
            dependencies: [
                "MCPSurface",
                "Persistence",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            swiftSettings: swift6
        ),
        .testTarget(
            name: "EgressGuardTests",
            dependencies: ["QwaveSupport", "Shields", "VPNKit", "MemoryWave", "BrowserCore"],
            swiftSettings: swift6
        ),
    ]
)
