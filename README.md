# 🌊 Qwave — Sovereign WebKit-Native macOS Browser Engine

[![Qwave CI](https://github.com/peterlodri-sec/qwave/actions/workflows/ci.yml/badge.svg)](https://github.com/peterlodri-sec/qwave/actions/workflows/ci.yml)
[![Release v0.1.0](https://img.shields.io/github/v/release/peterlodri-sec/qwave?color=00f2fe&style=flat-square)](https://github.com/peterlodri-sec/qwave/releases/tag/v0.1.0)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg?style=flat-square)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-macOS%2014.0%2B-black?style=flat-square&logo=apple)](https://apple.com)

![Qwave Hero Banner](docs/assets/hero.jpg)

**Qwave** is a high-performance, WebKit-native, battery-optimized sovereign macOS web browser. It combines **Firefox-style Container Universes**, **Brave-style Content Blocking**, **Tab Hibernation Memory Management**, **Safari SPI Feature Toggles**, and **Mullvad WireGuard VPN Integration**.

Built with modern **Swift 5.10**, **XcodeGen**, and **SPM Modular Architecture**.

---

## ⚡ Key Features

* 🪐 **Firefox Container Isolation**: Per-container isolated `WKWebsiteDataStore(forIdentifier:)` contexts and ephemeral non-persistent burner tabs.
* 🛡️ **Brave Content Shields**: Curated 51-rule `WKContentRuleList` engine, per-host JavaScript toggles, and HTTPS-First upgrader.
* 🔋 **Energy Governor**: `TabHibernator` memory manager that unloads background WebKit processes while preserving tab state and scroll position.
* 🎛️ **Safari SPI Feature Flags**: Safe `responds(to:)`-guarded reflection exposing 100+ Safari Technology Preview experimental feature flags (`_WKFeature`).
* 🔒 **Mullvad VPN Integration (Stage A)**: WireGuardKit system extension (`PacketTunnel.systemextension`) architecture using `NETunnelProviderManager`.
* 💾 **Raw SQLite Storage**: Fast WAL-mode SQLite database engine for browser history, bookmarks, and persistent session restoration.

---

## 🏗️ Architecture Overview

```mermaid
graph TD
    App["Qwave.app (AppKit Shell)"] --> Core["QwaveKit.framework"]
    App --> TunnelExt["PacketTunnel.systemextension"]
    
    subgraph QwaveKit ["Packages/QwaveKit (SPM Package)"]
        Core --> BrowserCore["BrowserCore"]
        Core --> Shields["Shields (WKContentRuleList)"]
        Core --> FeatureFlags["FeatureFlags (Safari SPI)"]
        Core --> VPNKit["VPNKit (Mullvad API & TunnelManager)"]
        Core --> Persistence["Persistence (SQLite WAL)"]
        Core --> QwaveSupport["QwaveSupport (Log & Keychain)"]
    end
    
    subgraph Tunnel ["Packages/WireGuardKit"]
        TunnelExt --> WGGo["libwg-go.a (WireGuard Go)"]
        TunnelExt --> WGC["WireGuardKitC"]
    end
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

---

## 📦 Releases

Download pre-compiled unsigned `Qwave.app` builds directly from [GitHub Releases](https://github.com/peterlodri-sec/qwave/releases).

---

## 📜 License

MIT License. Copyright (c) 2026 8b.is / Peter Lodri. See [LICENSE](LICENSE) for details.
