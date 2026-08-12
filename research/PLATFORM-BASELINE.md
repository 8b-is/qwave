# 🧱 Platform Baseline — August 2026

The floor every package note in this folder assumes. Qwave currently targets **macOS 14.0+ /
Swift 5.10**; this document records how far the platform has moved past that, so raising the
floor is a deliberate decision rather than an accident.

---

## 🖥️ Operating system

| Release | Status as of 2026-08-12 |
|---------|-------------------------|
| macOS 26 "Tahoe" | Current shipping release. First Apple Silicon-only major release; Metal 4 baseline. |
| macOS 27 "Golden Gate" | In beta since WWDC26 (first developer beta 2026-06-08, public beta 2026-07-13). General release expected around September 2026. |

**Qwave's deployment target is macOS 14.0**, which is now **three majors behind**. That gap is
the single largest constraint in this research folder — most of the genuinely interesting APIs
(WebKit for SwiftUI, Foundation Models, Metal 4 tensors) require macOS 26+.

### The decision this forces

| Option | Consequence |
|--------|-------------|
| Stay on macOS 14 | Maximum install base. Everything modern must be `if #available`-gated or shipped as an optional module. |
| Raise to macOS 26 | Unlocks WebKit for SwiftUI, Foundation Models, Metal 4, `_WKFeature` stability. Drops Intel Macs entirely (they are already excluded — Apple Silicon only). |

**Recommendation:** hold the macOS 14 floor for the core browser, and gate every macOS 26+
capability behind availability checks in an optional module. Qwave already proves it can do
this safely — `FeatureFlags/FeatureFlagSafety.swift` is exactly this pattern applied to Safari
SPI.

---

## 🛠️ Toolchain

| Tool | Version | Notes |
|------|---------|-------|
| Swift | **6.4** (ships inside Xcode 27) | Backwards compatible with Swift 6.x; no breaking changes introduced. |
| Swift | **6.3** | Previous stable. `swift-testing` and `swift-build` tag their releases against it. |
| Swift | **6.2** | The "Approachable Concurrency" release — the important one for Qwave. |
| Xcode | **27** (beta 4, 2026-07-20) | **Apple Silicon only.** Requires macOS 26.4+ to run. |
| Xcode | **26** | Current stable. |

### Swift 6.2 "Approachable Concurrency" — why it matters here

Qwave is pinned to **Swift 5.10 with the `targeted` concurrency stance** (`AGENTS.md` §3). The
6.2 model would materially simplify the codebase:

- **Single-threaded by default.** Executable targets and UI code run on the main actor without
  blanket `@MainActor` annotations. Qwave's AppKit shell (`Sources/QwaveApp`) is main-actor by
  nature and currently annotates that fact by hand.
- **`nonisolated async` defaults to `nonisolated(nonsending)`.** Async functions run on the
  caller's actor. This removes a large class of false-positive concurrency warnings and cuts
  actor hops — directly relevant to `TabManager` ↔ `TabHibernator` ↔ `EnergyGovernor`, which
  hand tab state across isolation boundaries on every hibernate/wake cycle.
- **Runtime concurrency diagnostics under test.** Catches data races that static analysis
  misses. Qwave's `BrowserCoreTests` exercise exactly the concurrent paths this would cover.
- **Pre-built swift-syntax.** Materially faster clean builds for any target using macros —
  which is every modern package in this research folder.

Enable per-package with the upcoming-feature flags in `Package.swift`, not globally, so the
migration can proceed one module at a time.

### SwiftPM

- `swift package show-traits` — package traits are now discoverable from the CLI. XcodeGen 2.46
  added trait support for remote and local package references, so traits are usable end-to-end
  in Qwave's generation pipeline today.
- Prebuilt swift-syntax binaries for shared macro libraries are supported.

---

## 🔩 Silicon

| Chip | Unified memory | Bandwidth |
|------|----------------|-----------|
| M5 | up to 32 GB | — |
| M5 Pro | up to 64 GB | up to 307 GB/s |
| M5 Max | up to 128 GB | up to 614 GB/s |

The architectural change that matters: **a Neural Accelerator in every GPU core**. Apple claims
up to 4× AI performance versus M4 Pro/Max and up to 8× versus M1. Apple's own MLX measurements
show **3.3×–4.06× faster time-to-first-token** on M5 versus M4 across Qwen 1.7B–14B and
GPT-OSS-20B. Taking advantage of the M5 Neural Accelerators from MLX requires **macOS 26.2+**.

### What this means for a browser

A browser is not an inference engine, and Qwave should not become one. But the hardware makes
three features cheap that were previously unaffordable:

1. **On-device page summarisation** — no network round-trip, no content leaving the machine.
   This is the sovereignty story, not a feature checkbox.
2. **Local heuristic content classification** — supplementing the static 51-rule
   `WKContentRuleList` with a model that scores unknown hosts.
3. **Private omnibox ranking** — reranking `HistoryStore` results locally instead of shipping
   queries to a search provider.

All three are **additive and optional**. None may become a startup dependency, and none may run
while the `EnergyGovernor` reports pressure.

---

## 📌 Version-pinning stance

| Concern | Position |
|---------|----------|
| Swift language mode | Migrate 5.10 → 6.2 module-by-module via upcoming-feature flags. Do not flip the whole package at once. |
| Deployment target | Hold at macOS 14 for core; gate macOS 26+ capabilities behind `#available`. |
| Dependency count | Every added dependency is attack surface for a sovereign browser. Prefer platform frameworks; prefer Apple-maintained packages; audit the rest. |
| WireGuard pin | Stays at `2fec12a6e1f6e3460b6ee483aa00ad29cddadab1` until the tunnel is tested end-to-end against a newer revision. |

---

*Verified 2026-08-12. Re-verify before acting on any version claim here.*
