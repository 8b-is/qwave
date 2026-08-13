# Qwave — Mac Silicon Swift Package Research

Bleeding-edge Swift packages evaluated **for Qwave specifically** — every
note is written against Qwave's actual modules (`Shields`, `VPNKit`,
`PostQuantum`, `WebExtensions`, `Persistence`, `BrowserCore`, `QwaveSupport`)
and its actual constraints (VPN routing guarantees, arm64+x86_64 universal
builds, unsigned-today distribution, 150-test SPM suite).

Versions were verified live on 2026-08-12 against GitHub release pages where
marked; others are approximate and stamped for re-verification. See
[PLATFORM-BASELINE.md](PLATFORM-BASELINE.md) for the assumed OS/toolchain
floor and the stamping rules.

**New (2026-08-13):** [BLEEDING-EDGE-2026.md](BLEEDING-EDGE-2026.md) — the
wider Mac-stack brief (Apple Silicon M5/Metal 4, WebGPU, Wasm 3.0/WASI,
Swift 6.3/6.4, Zig 0.16, interop playbook), including a Qwave-verified
correction: WebGPU in `WKWebView` is **not** on by default — it's the
`_WKFeature` `WebGPUEnabled` plus a secure context, reachable through
`FeatureFlagService`'s existing reflection.

## Categories

| Category | Packages | Headline verdicts |
|---|---|---|
| [apple-silicon](apple-silicon/README.md) | 4 | MLX Swift **Trial**; WhisperKit/MLX-LLM/MetalPetal **Hold** |
| [databases](databases/README.md) | 3 | GRDB **Adopt**; SQLite.swift **Hold**; DuckDB **Assess** |
| [collections-foundation](collections-foundation/README.md) | 3 | swift-collections **Adopt**; **WebURL Adopt** (fixes a shielding bypass) |
| [build-tooling](build-tooling/README.md) | 4 | XcodeGen **Adopt**; swift-format **Adopt**; Tuist **Assess** |
| [distribution](distribution/README.md) | 2 | **Sparkle Adopt — gated on code signing** |
| [networking](networking/README.md) | 5 | **SwiftNIO Hold** (routing leak surface); OpenAPI **Assess** |
| [graphics-media](graphics-media/README.md) | 3 | Pure-Swift codecs **Assess** |
| [testing](testing/README.md) | 4 | swift-testing **Adopt**; snapshot-testing **Trial** |
| [adblocking](adblocking/README.md) | 3 | **SafariConverterLib Trial — license gate**; adblock-rust **Hold** |
| [crypto-security](crypto-security/README.md) | 3 | All **Hold** — CryptoKit + PostQuantum cover the needs |
| [logging-observability](logging-observability/README.md) | 4 | swift-log **Adopt**; Pulse **Trial (debug-only)** |
| [utilities](utilities/README.md) | 3 | swift-argument-parser **Adopt** (with first CLI) |

**41 package notes · 12 categories · verdicts: 8 Adopt, 5 Trial, 11 Assess, 17 Hold/Reference**

### Resolved open question — WebKit for SwiftUI (2026-08-13)

The research flagged an unknown: *does `WebPage.Configuration` (the macOS 26
SwiftUI WebKit surface) expose the `_WKFeature` hook that `FeatureFlagService`
reflects over?* Spiked against the Xcode 26.4 / macOS 26 SDK: **no.**
`WebPage.Configuration` has `websiteDataStore` (so container isolation
carries over) and `defaultNavigationPreferences`, but **no `preferences`
(`WKPreferences`) member** — the object `FeatureFlags` reaches `_features`
through. So WebKit-for-SwiftUI can **parallel** the current
`WKWebView` + `WKPreferences` path but **cannot replace** it while the
experimental Safari feature flags depend on `_WKFeature` reflection. Verdict
stays *Adopt (gated / additive)*, not *replacement*.

## The four findings that should drive the roadmap

1. **Code signing is the highest-leverage work in the repo.** Unsigned
   distribution is the weakest part of a security product — and the *same*
   fix unblocks the VPN (network extensions need a signed, notarised host).
   It gates Sparkle and the Stage-B tunnel end-to-end.
2. **Foundation `URL` and WebKit disagree about hosts.** IDN/confusable,
   backslash, and `user@evil@good` cases mean `ShieldsPolicy` can shield a
   page under one identity while WebKit loads another — a bypass class, not a
   style issue. `WebURL` closes it.
3. **51 rules is a demonstration, not a blocklist.** SafariConverterLib as a
   *build-time* tool scales it to EasyList size with zero new runtime
   dependencies. Gated on a license review (copyleft).
4. **The energy claim is untested.** `EnergyGovernorTests` verifies
   decisions; nothing measures reclaimed memory — and package-benchmark
   *can't* cover it either, since hibernated memory lives in WebKit's
   out-of-process content processes.
