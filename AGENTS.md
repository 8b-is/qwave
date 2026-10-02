# AGENTS.md — `qwave`

> **Web3 & WebKit-Native Sovereign Browser Node — macOS + iPhone**

`qwave` is a high-performance, battery-optimized, WebKit-native browser combining Firefox-style container isolation, Brave-style content shields, tab hibernation memory management, and a Rust sovereign core (egress allowlist + MEM8 wave substrate) behind a Swift WebKit shell. It runs on macOS 14+ and on iPhone (iOS 15+ — **minimum device: iPhone 13**).

---

## ✦ Tech Stack & Architecture

- **Language:** Swift 6 language mode (`.swiftLanguageMode(.v6)`), `swift-tools-version:6.2`. Deployment targets macOS 14.0 / iOS 15.0 (iPhone 13 minimum).
- **Toolchain:** CI pins Xcode 26.3 and asserts it provides **Swift 6.2** — that compiler, not your local one, is the ceiling. Development machines on 26.4.x run Swift 6.3.1, so code can compile locally and still fail CI. `Benchmarks/Package.swift` is deliberately left at tools 5.10; bumping it flips the default language mode and surfaces a real data race in the benchmark harness.
- **iPhone lane:** `Sources/QwaveIOS` — SwiftUI shell over the same WebViewFactory/shields core; no AppKit, no Sparkle.
- **Rust core:** `core/` — zero-dependency Rust staticlib (egress allowlist, WaveInt 79-byte frame, Rational). Built by a pre-build script, linked into the app, spoken through the C ABI (`core/include/qwave_core.h` → `RustCoreBridge.swift`). Swift is the WebKit shell; decisions live in Rust.
- **Build System:** XcodeGen (`project.yml` is the single source of truth; `Qwave.xcodeproj` is gitignored).
- **Core Engine:** WebKit `WKWebView`, `WKWebsiteDataStore`, `WKContentRuleList`.
- **Modular Package:** `Packages/QwaveKit` — 12 library targets and their tests: QwaveSupport, URLIdentity, Persistence, Shields, FeatureFlags, WebCredentials, BrowserCore, WebExtensions, MemoryWave, Summarize, QwaveUI, MCPSurface. Plus one executable target, QwaveMCP (`qwave-mcp`). (Authoritative source is `swift package dump-package`, not this list — check it if the two disagree.)
- **CI/CD:** GitHub Actions (`.github/workflows/ci.yml` & `release.yml`).

---

## 🛡️ Control & Build Rules

1. **Zero Xcode Hand-Edits:** Never manually edit `.xcodeproj` files. Always modify `project.yml` and run `xcodegen generate --spec project.yml`.
2. **Package Path:** SPM commands run via `swift test --package-path Packages/QwaveKit`.
3. **Concurrency Stance:** Swift 6 language mode, which means **complete** data-race checking, on by default. Do not add `-strict-concurrency=complete` — under `.v6` it is redundant, and `.unsafeFlags` bars the package from being consumed as a versioned dependency. Proven, not assumed: with the flag removed, and even with an explicit `=minimal`, the identical five diagnostics still fire.
4. **No VPN in-tree:** the WireGuard/VPN layer (PacketTunnel, WireGuardKit+Go bridge, Zig packet filter, VPNKit, PostQuantum) is removed — it is a different layer, not the browser's requirement. If it returns, it returns as a separate package/repo.
5. **iOS 15 floor:** iPhone 13 is the minimum device. Any API newer than iOS 15 goes behind `#available`/`#if canImport` with an honest degradation path (see `ContainerRegistry` and `SemanticEmbedder`), never a bare call.
6. **No AppKit in `Sources/QwaveIOS`:** the phone lane is SwiftUI-only. Shared QwaveKit files that need AppKit use the `#if canImport(AppKit)` gate (`DownloadsPopover`, `FindBarView` are the pattern).

*qwave · sovereign browser, two lanes · macOS + iPhone · 8b.is*
