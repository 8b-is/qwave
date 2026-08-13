# AGENTS.md — `qwave`

> **Web3 & WebKit-Native Sovereign macOS Browser Node**

`qwave` is a high-performance, battery-optimized, WebKit-native macOS browser combining Firefox-style container isolation, Brave-style content shields, tab hibernation memory management, and Mullvad WireGuard VPN integration.

---

## ✦ Tech Stack & Architecture

- **Language:** Swift 5.10 (macOS 14.0+ deployment target).
- **Build System:** XcodeGen (`project.yml` is the single source of truth; `Qwave.xcodeproj` is gitignored).
- **Core Engine:** WebKit `WKWebView`, `WKWebsiteDataStore`, `WKContentRuleList`.
- **Modular Package:** `Packages/QwaveKit` (9 modules: QwaveSupport, URLIdentity, Persistence, Shields, FeatureFlags, BrowserCore, VPNKit, PostQuantum, WebExtensions).
- **VPN Extension:** `Sources/PacketTunnel` WireGuardKit system extension (`NETunnelProviderManager`).
- **CI/CD:** GitHub Actions (`.github/workflows/ci.yml` & `release.yml`).

---

## 🛡️ Control & Build Rules

1. **Zero Xcode Hand-Edits:** Never manually edit `.xcodeproj` files. Always modify `project.yml` and run `xcodegen generate --spec project.yml`.
2. **Package Path:** SPM commands run via `swift test --package-path Packages/QwaveKit`.
3. **Concurrency Stance:** Swift 5.10 + `targeted` concurrency stance.
4. **WireGuard Pin:** Pinned to `wireguard/wireguard-apple @ 2fec12a6e1f6e3460b6ee483aa00ad29cddadab1`.

*qwave · best-of-three macOS browser · 8b.is*
