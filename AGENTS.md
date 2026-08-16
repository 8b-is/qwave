# AGENTS.md — `qwave`

> **Web3 & WebKit-Native Sovereign macOS Browser Node**

`qwave` is a high-performance, battery-optimized, WebKit-native macOS browser combining Firefox-style container isolation, Brave-style content shields, tab hibernation memory management, and Mullvad WireGuard VPN integration.

---

## ✦ Tech Stack & Architecture

- **Language:** Swift 6 language mode (`.swiftLanguageMode(.v6)`), `swift-tools-version:6.2`. Deployment targets macOS 14.0 / iOS 17.0.
- **Toolchain:** CI pins Xcode 26.3 and asserts it provides **Swift 6.2** — that compiler, not your local one, is the ceiling. Development machines on 26.4.x run Swift 6.3.1, so code can compile locally and still fail CI. `Benchmarks/Package.swift` is deliberately left at tools 5.10; bumping it flips the default language mode and surfaces a real data race in the benchmark harness.
- **Build System:** XcodeGen (`project.yml` is the single source of truth; `Qwave.xcodeproj` is gitignored).
- **Core Engine:** WebKit `WKWebView`, `WKWebsiteDataStore`, `WKContentRuleList`.
- **Modular Package:** `Packages/QwaveKit` — **13 library targets** and 13 test targets: QwaveSupport, URLIdentity, Persistence, Shields, FeatureFlags, WebCredentials, BrowserCore, PostQuantum, VPNKit, WebExtensions, MemoryWave, Summarize, QwaveUI. (Authoritative source is `swift package dump-package`, not this list — check it if the two disagree.)
- **VPN Extension:** `Sources/PacketTunnel` WireGuardKit system extension (`NETunnelProviderManager`).
- **CI/CD:** GitHub Actions (`.github/workflows/ci.yml` & `release.yml`).

---

## 🛡️ Control & Build Rules

1. **Zero Xcode Hand-Edits:** Never manually edit `.xcodeproj` files. Always modify `project.yml` and run `xcodegen generate --spec project.yml`.
2. **Package Path:** SPM commands run via `swift test --package-path Packages/QwaveKit`.
3. **Concurrency Stance:** Swift 6 language mode, which means **complete** data-race checking, on by default. Do not add `-strict-concurrency=complete` — under `.v6` it is redundant, and `.unsafeFlags` bars the package from being consumed as a versioned dependency. Proven, not assumed: with the flag removed, and even with an explicit `=minimal`, the identical five diagnostics still fire.
4. **WireGuard Pin:** Pinned to `wireguard/wireguard-apple @ 2fec12a6e1f6e3460b6ee483aa00ad29cddadab1`.

*qwave · best-of-three macOS browser · 8b.is*
