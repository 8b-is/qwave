# QWEN.md — Qwave

> **WebKit-native macOS browser** | Swift 5.10 | macOS 14.0+ | XcodeGen

High-performance, battery-optimized sovereign browser combining Firefox-style container isolation, Brave-style content shields, tab hibernation, Mullvad WireGuard VPN with post-quantum PSK, Safari SPI feature toggles, WebExtensions MV3 engine, and an on-device memory wave substrate.

---

## Build & Run

### Prerequisites

- macOS 14.0+
- Xcode 15.3+ / 16+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- [xcbeautify](https://github.com/cpforge/xcbeautify) (`brew install xcbeautify`)
- Go toolchain (for WireGuardKitGo `libwg-go.a`): `brew install go`

### Commands

```bash
# Unit tests (Release for ~10x faster post-quantum KATs)
swift test -c release --package-path Packages/QwaveKit

# Generate Xcode project from project.yml (never hand-edit .xcodeproj)
xcodegen generate --spec project.yml

# Build unsigned Release
xcodebuild \
  -project Qwave.xcodeproj \
  -scheme Qwave \
  -configuration Release \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY= \
  build | xcbeautify

# Format lint
xcrun swift-format lint --strict --recursive \
  Sources \
  Packages/QwaveKit/Sources \
  Packages/QwaveKit/Tests \
  Packages/QwaveKit/Package.swift \
  Benchmarks/Benchmarks \
  Benchmarks/Package.swift

# Local release (mirrors CI)
./scripts/release.sh v0.4.3
```

**Env vars for signed/notarized builds** (see docs/SIGNING.md):
`QWAVE_SIGN_IDENTITY`, `QWAVE_TEAM_ID`, `QWAVE_NOTARY_PROFILE`, `QWAVE_SPARKLE_KEY`

---

## Architecture

```
Qwave.app (AppKit shell)
├── QwaveKit (SPM: 10 modules)
├── PacketTunnel.systemextension (WireGuardKit + QwaveTunnelKit)
└── Resources (Info.plist, entitlements, built-in rule lists)
```

### Module dependency graph

```
QwaveApp → {BrowserCore, Shields, FeatureFlags, VPNKit, Persistence, QwaveSupport}
PacketTunnel → {VPNKit, QwaveSupport, WireGuardKit}
```

| Module | Role |
|---|---|
| `QwaveSupport` | Logging (`QwaveLog`), keychain (`SecretStore`) |
| `URLIdentity` | WHATWG-canonical host identity (closes Foundation-vs-WebKit parser bypass class) |
| `Persistence` | WAL-mode SQLite (history, bookmarks, settings, sessions) |
| `Shields` | `WKContentRuleList` compilation, uBO/EasyList parser, HTTPS-first upgrader, remote blocklist updater |
| `FeatureFlags` | Safari `_WKFeature` SPI reflection (`responds(to:)`-guarded) |
| `BrowserCore` | Tabs, containers, navigation, hibernation, energy governor, internal pages, downloads |
| `VPNKit` | Mullvad API client, relay selection, tunnel manager, post-quantum peer negotiation |
| `PostQuantum` | Pure-Swift Keccak/SHAKE, ML-KEM-768 (FIPS 203), Classic McEliece 348864, `HybridKEM` |
| `WebExtensions` | MV3 manifest registry, `browser.*` JS bridge, extension storage, popups |
| `MemoryWave` | MEM8 cognitive substrate: 79-byte `WaveInt`, sparse grid, Marine salience, AES-GCM store, AI-agnostic providers |

### Key design decisions

- **Energy**: single coalesced `DispatchSourceTimer` (30s + 10s leeway) drives all hibernation + energy management — no per-tab timers.
- **Hibernation**: `WKWebView.interactionState` captures full back/forward stack + scroll + form state; restoring a session starts all tabs hibernated, spawning one web process on first selection.
- **Containers**: `WKWebsiteDataStore(forIdentifier:)` — separate cookie jars, caches, service workers per container. Ephemeral tabs use `.nonPersistent()`.
- **Shields**: declarative `WKContentRuleList` enforced in WebKit's network layer, not JS-injected. HTTPS-first: rule list for subresources + state machine for main-frame navigations.
- **Post-quantum**: Hybrid ML-KEM-768 + Classic McEliece 348864 PSK negotiation. Fail-closed: no silent classic fallback.
- **Memory Wave**: Memories never leave the Mac. Remote providers receive titles + times only, never page bodies. Ephemeral/private tabs cannot write.

---

## Project Layout

```
qwave/
├── project.yml                 # XcodeGen spec — single source of truth
├── Packages/
│   ├── QwaveKit/               # SPM package (10 modules + tests)
│   │   ├── Sources/            # Module source code
│   │   ├── Tests/              # 39 test files across all modules
│   │   └── .periphery.yml      # Dead-code scan config (report-only)
│   └── WireGuardKit/           # Vendored (pinned at 2fec12a6e1f6)
├── Sources/
│   ├── QwaveApp/               # AppKit shell (25 Swift files)
│   └── PacketTunnel/           # NETunnelProvider system extension
├── Resources/                  # Entitlements, Info.plists, CI dist profiles
│   └── CI/                     # Distribution-NoVPN.entitlements for CI builds
├── Benchmarks/                 # package-benchmark (mallocCountTotal thresholds)
├── docs/                       # ARCHITECTURE, SIGNING, VPN_STAGE_B, ENERGY, BLOCKLIST, CRYPTO_REVIEW, RELEASING
├── scripts/
│   ├── release.sh              # Local release pipeline (mirrors CI)
│   └── update-blocklist.sh     # Regenerate EasyList snapshot via SafariConverterLib
├── research/                   # 41 package evaluations across 12 categories
└── .github/workflows/
    ├── ci.yml                  # format lint, unit tests, build, dead-code, benchmarks
    └── release.yml             # Build, sign, notarize, DMG, Sparkle appcast
```

---

## Development Conventions

### Code style

- **Formatter**: `swift-format` with `--strict` (4-space indent, 120-char line length). CI enforces. Committed `.swift-format` config.
- **Concurrency**: Swift 5.10 `targeted` strictness. `@MainActor` on app-layer classes. Pure models are `Sendable` where possible.
- **Naming**: Swift conventions. Public API has doc comments. Internal/private code is self-documenting.
- **Logging**: Use `QwaveLog.{subsystem}.{level}("\(value, privacy: .public|.private)")`. Privacy redaction is enforced at the call site — private values are replaced with `<private>` before entering the swift-log pipeline.
- **Dependency rule**: `BrowserCore` is the only module allowed to import other feature modules (it hosts `WebViewFactory`, the convergence point).

### Testing

- **Framework**: XCTest (older tests) + Swift Testing `@Test` (newer tests). Both coexist.
- **Test location**: `Packages/QwaveKit/Tests/<Module>Tests/` — one test file per module area.
- **CI mode**: `swift test -c release` — post-quantum KATs are ~10x faster in Release.
- **KAT vectors**: Generated from independent Python oracle, never from the Swift implementation under test. Bundled as JSON fixtures in test targets.
- **Snapshot testing**: `swift-snapshot-testing` for uBO → content-blocker compiler golden files.
- **Mocking**: `URLProtocol`-mockable for Mullvad API client tests (`MockURLProtocol`).
- **Benchmarks**: `package-benchmark` with CI-checked `mallocCountTotal` thresholds (deterministic per code path). Requires jemalloc.

### CI/CD

- **Runner**: Blacksmith `macos-15` (6 vcpu). Xcode 16.4 pinned explicitly.
- **Jobs**: format lint → unit tests → build app → dead-code report (non-blocking) → benchmarks.
- **Release**: Tag `v*` triggers signed/notarized build + DMG + Sparkle appcast. Falls back to unsigned when Developer ID secrets absent.
- **Versioning**: `CFBundleShortVersionString` = `MAJOR.MINOR.PATCH`; `CFBundleVersion` = `MAJOR*10000 + MINOR*100 + PATCH`. CI enforces tag matches both.
- **Sparkle**: EdDSA-signed updates. `SUPublicEDKey` in `project.yml`. CI verifies the private key pairs with the committed public key.

### Security

- **Secrets**: WireGuard device private keys live in Keychain (shared keychain group). Tunnel config carries no key material (verified by `TunnelSessionConfig` tests).
- **Crypto**: Post-quantum module has a self-audit in `docs/CRYPTO_REVIEW.md`. KATs are deterministic. McEliece decoder is documented as variable-time (not attacker-chosen ciphertexts).
- **Reporting**: Via GitHub Security Advisories. No public issues for security reports.
- **Threat model**: Malicious web content, network attackers (on-path), update-channel attackers, harvest-now-decrypt-later. Out of scope: compromised local machine, timing side channels on McEliece decoder, Mullvad relay compromise.

### WireGuard pin

Pinned to `wireguard/wireguard-apple @ 2fec12a6e1f6e3460b6ee483aa00ad29cddadab1`. Go bridge builds `libwg-go.a` at compile time via pre-build script.

### Formatter .git-blame-ignore-revs

Commit `e647e706ab933e819fef71c30009cee011972b63` is the initial swift-format reformat — add to `.git-blame-ignore-revs` for `git blame` to skip.

### Periphery dead-code scan

Report-only (non-blocking CI job). Config at `Packages/QwaveKit/.periphery.yml`. `retain_public: true` (QwaveKit is a library consumed by app target Periphery can't see). `retain_objc_accessible: true` (AppKit/WebKit runtime reachability). Tests excluded from report.

---

## Version History

| Version | Date | Highlights |
|---|---|---|
| 0.4.3 | 2026-08-13 | Memory nibbles (tagged markdown files), CI Release-mode tests |
| 0.4.2 | 2026-08-13 | Remember Everything, timeline slate (`qwave://timeline`) |
| 0.4.1 | 2026-08-13 | Wave start page, markdown reader, directory fallback |
| 0.4.0 | 2026-08-13 | MemoryWave module (MEM8 cognitive substrate), fail-closed policy |
| 0.3.1 | 2026-08-13 | First signed+notarized+Sparkle build, ENERGY.md measurement protocol |
| 0.3.0 | 2026-08-13 | Signing/notarization pipeline, WebURL host identity fix, EasyList snapshot, swift-log |
| 0.2.0 | 2026-08-13 | WebExtensions MV3, post-quantum Stage B, uBO/EasyList compiler |
| 0.1.0 | 2026-08-13 | Browser core, containers, shields, Mullvad VPN Stage A |