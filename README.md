# 🌊 Qwave — Sovereign WebKit-Native macOS Browser Engine

[![Qwave CI](https://github.com/peterlodri-sec/qwave/actions/workflows/ci.yml/badge.svg)](https://github.com/peterlodri-sec/qwave/actions/workflows/ci.yml)
[![Release v0.2.0](https://img.shields.io/github/v/release/peterlodri-sec/qwave?color=00f2fe&style=flat-square)](https://github.com/peterlodri-sec/qwave/releases/tag/v0.2.0)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg?style=flat-square)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-macOS%2014.0%2B-black?style=flat-square&logo=apple)](https://apple.com)

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
| `QwaveSupport` | Logging (`QwaveLog`) and keychain helpers |

`Packages/WireGuardKit` (vendored) supplies the WireGuard Go bridge + C module for the tunnel extension.

```
Qwave.app (AppKit shell)
├── QwaveKit (SPM umbrella: 8 modules above)
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
[research/README.md](research/README.md) for the index and
[research/PLATFORM-BASELINE.md](research/PLATFORM-BASELINE.md) for the assumed
platform floor.

The four findings that drive the roadmap:
1. **Code signing** is the highest-leverage work — it gates Sparkle, the VPN
   extension, and Stage B end-to-end.
2. Foundation `URL` and WebKit disagree about host identity — `WebURL` closes
   a `ShieldsPolicy` bypass class.
3. The 51-rule starter list is a demonstration; **SafariConverterLib** (build
   time) scales Shields to EasyList size — gated on a copyleft license review.
4. The energy claim needs real measurement; hibernated memory lives in
   WebKit's out-of-process content processes, so benchmarks can't see it.

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
| Code signing + notarisation + Sparkle updates | 🔜 planned |
| Shields list scale-up (SafariConverterLib) | 🔜 gated on license review |
| Local AI features (MLX) | 🧪 research only |

---

## 📦 Releases

Download pre-compiled unsigned `Qwave.app` builds directly from [GitHub Releases](https://github.com/peterlodri-sec/qwave/releases).

---

## 📜 License

MIT License. Copyright (c) 2026 8b.is / Peter Lodri. See [LICENSE](LICENSE) for details.
