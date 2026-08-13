# 🌊 Qwave — Sovereign WebKit-Native macOS Browser Engine

[![Qwave CI](https://github.com/8b-is/qwave/actions/workflows/ci.yml/badge.svg)](https://github.com/8b-is/qwave/actions/workflows/ci.yml)
[![Release v0.3.0](https://img.shields.io/github/v/release/8b-is/qwave?color=00f2fe&style=flat-square)](https://github.com/8b-is/qwave/releases/tag/v0.3.0)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg?style=flat-square)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-macOS%2014.0%2B-black?style=flat-square&logo=apple)](https://apple.com)
[![Swift](https://img.shields.io/badge/Swift-5.10-orange?style=flat-square&logo=swift)](https://swift.org)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-999?style=flat-square&logo=apple)](https://apple.com/mac)

![Qwave Hero Banner](docs/assets/hero.jpg)

**Qwave** is a high-performance, WebKit-native, battery-optimized sovereign macOS web browser. It combines **Firefox-style Container Universes**, **Brave-style Content Blocking**, **Tab Hibernation Memory Management**, **Safari SPI Feature Toggles**, **Mullvad WireGuard VPN Integration**, **Post-Quantum PSK Negotiation**, and a **WebExtensions MV3 Engine**.

Built with modern **Swift 5.10**, **XcodeGen**, and **SPM Modular Architecture**.

---

## ⚡ Key Features

* 🪐 **Firefox Container Isolation**: Per-container isolated `WKWebsiteDataStore(forIdentifier:)` contexts and ephemeral non-persistent burner tabs.
* 🛡️ **Brave Content Shields**: Curated `WKContentRuleList` engine, uBlock/EasyList syntax compiler, per-host JavaScript toggles, and HTTPS-First upgrader.
* 🔋 **Energy Governor**: `TabHibernator` memory manager that unloads background WebKit processes while preserving tab state and scroll position.
* 🎛️ **Safari SPI Feature Flags**: Safe `responds(to:)`-guarded reflection exposing Safari Technology Preview experimental feature flags (`_WKFeature`).
* 🔒 **Mullvad VPN + Post-Quantum Stage B**: WireGuardKit system extension (`PacketTunnel.systemextension`) with hybrid ML-KEM-768 + Classic McEliece 348864 PSK negotiation (see [docs/VPN_STAGE_B.md](docs/VPN_STAGE_B.md)).
* 🧩 **WebExtensions MV3 Engine**: `browser.*` JS bridge (`tabs` / `storage.local` / `runtime.sendMessage`), file-backed storage, and `NSPopover` extension popups.
* 💾 **Raw SQLite Storage**: Fast WAL-mode SQLite database engine for browser history, bookmarks, and persistent session restoration.

---

## 🧭 Module Map

`Packages/QwaveKit/Package.swift` is the source of truth:

| Module | Purpose |
|---|---|
| `BrowserCore` | Tabs, containers, navigation, hibernation, downloads |
| `Shields` | Content blocking (`WKContentRuleList`), uBO/EasyList compiler, HTTPS-first, remote blocklist updater (ETag-cached) |
| `FeatureFlags` | Safari SPI feature toggles (`responds(to:)`-guarded) |
| `VPNKit` | Mullvad API client, relay selection, tunnel manager, post-quantum peer negotiation |
| `PostQuantum` | Pure-Swift Keccak/SHAKE, ML-KEM-768 (FIPS 203), Classic McEliece 348864, `HybridKEM` |
| `WebExtensions` | MV3 manifest registry, `browser.*` bridge, extension storage, popups |
| `Persistence` | WAL-mode SQLite stores (history, bookmarks, sessions) |
| `MemoryWave` | MEM8 wave substrate: 79-byte `WaveInt`, Cognitive/Nexus provenance, container-scoped AES-GCM store, Marine salience, AI-agnostic providers (on-device / OpenAI-compatible). Stored memories never leave the Mac. |
| `QwaveSupport` | Logging (`QwaveLog`) and keychain helpers |

`Packages/WireGuardKit` (vendored) supplies the WireGuard Go bridge + C module for the tunnel extension.

```
Qwave.app (AppKit shell)
├── QwaveKit (SPM umbrella: 10 modules above)
├── PacketTunnel.systemextension (WireGuardKit + QwaveTunnelKit)
└── Resources (Info.plist, entitlements, built-in rule lists)
```

---

## 📁 Repository Layout

```
qwave/
├── Packages/
│   ├── QwaveKit/          # The modular SPM package (8 modules + tests)
│   └── WireGuardKit/      # Vendored WireGuard Swift/Go/C kit
├── Sources/
│   ├── QwaveApp/          # AppKit shell: toolbar, tabs, settings, VPN status item
│   └── PacketTunnel/      # NETunnelProvider packet tunnel
├── Resources/             # Info.plists, entitlements, bundled rule lists
├── docs/                  # ARCHITECTURE, SIGNING, VPN_STAGE_B
├── research/              # Mac Silicon Swift package research (see below)
├── .github/workflows/     # ci.yml, release.yml
└── project.yml            # XcodeGen spec — the ONLY project source of truth
```

---

## 🚀 Quick Start & Building Locally

### Prerequisites
- macOS 14.0 or newer
- Xcode 15.3+ / Xcode 16+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- [xcbeautify](https://github.com/cpforge/xcbeautify) (`brew install xcbeautify`)

### 1. Run SPM Unit Tests
```bash
swift test --package-path Packages/QwaveKit
```

### 2. Generate Xcode Project & Build
```bash
# Generate Qwave.xcodeproj from project.yml
xcodegen generate --spec project.yml

# Build Release unsigned bundle
xcodebuild \
  -project Qwave.xcodeproj \
  -scheme Qwave \
  -configuration Release \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY= \
  build | xcbeautify
```

### Development rules
1. **Never hand-edit `.xcodeproj`** — change `project.yml`, run `xcodegen generate`.
2. **SPM commands** run via `swift test --package-path Packages/QwaveKit`.
3. **Concurrency stance**: Swift 5.10, `targeted` strictness.
4. **WireGuard pin**: `wireguard/wireguard-apple @ 2fec12a6e1f6e3460b6ee483aa00ad29cddadab1`.

---

## 🔬 Package Research (`research/`)

Bleeding-edge Apple Silicon Swift packages evaluated **for Qwave specifically**
— 41 package notes across 12 categories, each with a fact table (repo ·
version · license · platforms · Apple Silicon status), adoption sketch, risks
and an **Adopt / Trial / Assess / Hold** verdict. See
[research/README.md](research/README.md) for the index,
[research/DIGEST.md](research/DIGEST.md) for the consolidated digest,
[research/BLEEDING-EDGE-2026.md](research/BLEEDING-EDGE-2026.md) for the
wider Mac-stack brief (M5/Metal 4, WebGPU, Wasm/WASI, Swift, Zig), and
[research/PLATFORM-BASELINE.md](research/PLATFORM-BASELINE.md) for the assumed
platform floor.

The four findings that drove the v0.3.0 roadmap (all landed):
1. **Code signing** was the highest-leverage work — the release pipeline now
   signs, notarises and ships Sparkle auto-updates when the Developer ID
   secrets are configured (see [docs/SIGNING.md](docs/SIGNING.md)).
2. Foundation `URL` and WebKit disagree about host identity — `WebURL`
   (the `URLIdentity` module) now derives every policy host, closing a
   `ShieldsPolicy` bypass class.
3. The 51-rule starter list was a demonstration; the bundled list is now a
   compiled EasyList snapshot (~59k rules) produced by SafariConverterLib as
   an external build-time tool — license boundary documented in
   [docs/BLOCKLIST.md](docs/BLOCKLIST.md).
4. The energy claim needs real measurement; hibernated memory lives in
   WebKit's out-of-process content processes, so in-process benchmarks can't
   see it — measurement protocol in [docs/ENERGY.md](docs/ENERGY.md).

---

## 📊 Project Status

| Area | Status |
|---|---|
| Browser core (containers, tabs, hibernation) | ✅ v0.1.0 |
| Shields + HTTPS-first | ✅ v0.1.0 |
| Mullvad VPN Stage A (classic WireGuard) | ✅ v0.1.0 |
| WebExtensions MV3 engine | ✅ v0.2.0 |
| Post-quantum Stage B (ML-KEM-768 + McEliece hybrid) | ✅ v0.2.0 |
| uBO/EasyList rule compiler + ETag updater | ✅ v0.2.0 |
| Menu-bar VPN widget (throughput + server switch) | ✅ v0.2.0 |
| Signing/notarisation pipeline + Sparkle 2.9.5 auto-updates | ✅ v0.3.0 |
| Canonical host identity (`WebURL`) — shielding bypass fix | ✅ v0.3.0 |
| Compiled EasyList snapshot (~59k rules) | ✅ v0.3.0 |
| swift-log structured logging with privacy redaction | ✅ v0.3.0 |
| VPN extension in CI-signed builds | 🔜 needs Apple NE Developer ID approval |
| Memory Wave (MEM8 substrate + AI-agnostic inference) | ✅ v0.4.0 |
| Local MLX weights | 🧪 research only |

---

## ⚡ Performance

- **[hot_paths.md](hot_paths.md)** — Ranked hot paths with real measurements, optimisations applied, and what we chose not to optimise.
- **[swift_tips_tricks.md](swift_tips_tricks.md)** — Performance patterns discovered during Qwave's optimisation work: string/collection techniques, SQLite prepared-statement caching, `@inlinable` guidance, and Apple Silicon specifics.

---

## 📦 Releases

Download pre-compiled unsigned `Qwave.app` builds directly from [GitHub Releases](https://github.com/8b-is/qwave/releases).

---

## 📜 License

MIT License. Copyright (c) 2026 8b.is / Peter Lodri. See [LICENSE](LICENSE) for details.
