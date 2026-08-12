# 🔬 Qwave Research

Bleeding-edge **Apple Silicon / Swift** package research, organised **per category** and
**per package**, scoped to what a WebKit-native sovereign macOS browser actually needs.

> **Verification date:** `2026-08-12`
> Every package note records the version that was live on that date. Versions move fast —
> re-verify before you pin anything in `Package.swift` or `project.yml`.

---

## 📚 Categories

| # | Category | Focus | Packages |
|---|----------|-------|----------|
| 01 | [WebKit & Browser Engine](01-webkit-browser-engine/) | Rendering, URL semantics, content blocking | 4 |
| 02 | [On-Device AI & ML](02-on-device-ai/) | Local inference on the Neural Accelerators | 5 |
| 03 | [GPU, Metal & Compute](03-gpu-metal-compute/) | Metal 4, tensors, image pipelines | 3 |
| 04 | [Concurrency & Runtime](04-concurrency-runtime/) | Swift 6.x concurrency, data structures | 4 |
| 05 | [Persistence & Data](05-persistence-data/) | SQLite, type-safe SQL, observation | 3 |
| 06 | [Networking & Protocols](06-networking/) | NIO, HTTP types, async clients | 3 |
| 07 | [Security, Crypto & VPN](07-security-crypto-vpn/) | CryptoKit parity, X.509, WireGuard | 4 |
| 08 | [UI: AppKit & SwiftUI](08-ui-appkit-swiftui/) | Shell chrome, shortcuts, preferences | 4 |
| 09 | [Build & Tooling](09-build-tooling/) | Project generation, lint, format, dead code | 6 |
| 10 | [Testing & Quality](10-testing-quality/) | Swift Testing, snapshots | 2 |
| 11 | [Performance & Energy](11-performance-energy/) | Benchmarking the Energy Governor | 1 |
| 12 | [Distribution & Updates](12-distribution-updates/) | Signed auto-update delivery | 1 |

Start with **[PLATFORM-BASELINE.md](PLATFORM-BASELINE.md)** — the OS, toolchain and silicon
floor that every note below assumes.

---

## 🧭 How to read a package note

Every `*.md` under a category folder follows the same shape:

```
Fact table        repo · version · license · platforms · Apple Silicon status
What it is        one paragraph, no marketing
Why it matters    the concrete Qwave module it touches
Apple Silicon     what changes on M-series specifically
Adoption sketch   the smallest real code that proves it out
Risks             what bites you at integration time
Verdict           Adopt · Trial · Assess · Hold
```

### Verdict scale

| Verdict | Meaning |
|---------|---------|
| 🟢 **Adopt** | Production-ready for Qwave today; pin it and ship it. |
| 🔵 **Trial** | Strong candidate — build a spike behind a feature flag first. |
| 🟡 **Assess** | Interesting, real, but the integration cost or API churn is unresolved. |
| 🔴 **Hold** | Do not add. Recorded so nobody re-litigates it in six months. |

---

## 📊 Verdict roll-up

| Verdict | Packages |
|---------|----------|
| 🟢 Adopt | WebKit for SwiftUI · WebURL · GRDB · swift-crypto · WireGuardKit · swift-collections · XcodeGen · swift-testing · swift-format · Sparkle |
| 🔵 Trial | SafariConverterLib · MLX Swift · Foundation Models · swift-async-algorithms · KeyboardShortcuts · Defaults · package-benchmark · Periphery · swift-snapshot-testing · swift-certificates |
| 🟡 Assess | adblock-rust · mlx-swift-examples · swift-transformers · Metal 4 · Alloy · SQLiteData · swift-structured-queries · swift-http-types · swift-subprocess · Tuist · SwiftLint · swift-navigation · SwiftUI Introspect |
| 🔴 Hold | WhisperKit · MetalPetal · SwiftNIO · AsyncHTTPClient · swift-atomics · swift-build · mullvadvpn-app |

A 🔴 **Hold** is not a quality judgement — most of them are excellent packages that simply do
not belong in a browser shell. The reasoning is written down in each note.

---

## ⚖️ Standing constraints

These are Qwave rules, not preferences. They kill otherwise-attractive packages.

1. **Zero Xcode hand-edits.** Dependencies enter through `project.yml` + `Packages/QwaveKit/Package.swift`.
2. **App Store-compatible licensing.** GPL/LGPL-linked code cannot ship inside `Qwave.app`.
   It may still be used *offline*, at build time, to generate resources.
3. **Sovereignty.** No package may phone home at runtime. Network egress is the user's choice,
   made through the VPN and Shields panes — not a transitive dependency's telemetry.
4. **Energy first.** Anything that keeps a thread hot, polls, or defeats App Nap fights the
   `EnergyGovernor` and needs an explicit justification.
5. **Apple Silicon only.** `arm64` is the only architecture. Rosetta compatibility is not a
   design input.

---

*qwave · best-of-three macOS browser · 8b.is*
