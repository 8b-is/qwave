# 🌊 Qwave · Apple Silicon & Swift Package Research — Consolidated Digest

**The entire `research/` folder in one document.** Findings, verdicts, and the deep research
behind them, for a WebKit-native sovereign macOS browser.

| | |
|---|---|
| **Scope** | 12 categories · 40 packages · Apple Silicon / Swift ecosystem |
| **Verification date** | `2026-08-12` — all versions live-checked against upstream release pages on this date |
| **Subject** | [Qwave](../README.md) v0.1.0 — macOS 14.0+, Swift 5.10, 6 SPM modules, AppKit shell + SwiftUI panes |
| **Per-package notes** | [`research/`](README.md) — this document condenses them; each links to its full note |

**Verdict scale** — 🟢 **Adopt** (production-ready, pin it) · 🔵 **Trial** (spike behind a flag)
· 🟡 **Assess** (real, but integration cost unresolved) · 🔴 **Hold** (do not add; recorded so
nobody re-litigates it).

---

# Part I · Executive Summary

## The six findings that matter

Ranked by leverage — what changes the most for the least work.

### 1. 🔑 Code signing is the highest-leverage work available, and it is not a code change

Qwave ships as an **unsigned zip**. Every user downloads manually, bypasses Gatekeeper, and has
no way to learn a new version exists. For a browser, this is the single largest weakness in the
product: **a browser that cannot ship security updates quickly is not a secure browser.** Teaching
users to bypass Gatekeeper is its own harm — it normalises exactly the behaviour that makes
people vulnerable elsewhere.

The finding that makes this urgent rather than merely untidy: **the same fix unblocks the VPN.**
Network extensions require a signed, notarised host app with correct entitlements, so
`PacketTunnel.systemextension` cannot be fully approved by macOS today. One chain of work
delivers both:

```
Developer ID certificate → sign app + system extension → notarise + staple
        → Sparkle EdDSA-signed appcast → users get updates
        → macOS can approve the system extension → the VPN actually works
```

→ [Distribution & Updates](#12--distribution--updates) · [Sparkle](12-distribution-updates/sparkle.md)

### 2. 🌐 Foundation `URL` and WebKit disagree about what a host is — and that is a shield bypass

`URL` and `URLComponents` are RFC 3986-flavoured. The web runs on the **WHATWG URL Standard**,
and they diverge on cases that matter:

| Input | Foundation `URL` | WHATWG (what WebKit loads) |
|-------|------------------|----------------------------|
| `http:\\example.com\` | fails or misparses | → `http://example.com/` |
| `https://еxample.com` (Cyrillic `е`) | host preserved as typed | → `xn--xample-2of.com` |
| `https://user@evil.com@good.com/` | ambiguous | host is `good.com` |

Qwave makes host-keyed **security** decisions in `ShieldsPolicy` (per-host JS toggles),
`HTTPSFirstUpgrader` (scheme rewriting), `OmniboxParser`, and `HistoryStore`. If Qwave's host
differs from WebKit's, a page is **shielded under one identity and loaded under another**.

This is a correctness gap that is also a security gap, and it is cheap to close.

→ [WebURL](01-webkit-browser-engine/weburl.md)

### 3. 🧱 Swift 6.2 "Approachable Concurrency" would simplify the tab lifecycle

Qwave is pinned to **Swift 5.10 / `targeted` stance** while the toolchain has reached **6.4**.
The 6.2 model is not cosmetic here:

- **Main-actor-by-default** removes annotation noise from `Sources/QwaveApp/*`, which is
  main-actor by nature.
- **`nonisolated async` defaults to `nonisolated(nonsending)`** — runs on the caller's actor,
  removing actor hops and false-positive warnings on the `TabManager` ↔ `TabHibernator` ↔
  `EnergyGovernor` path, where state crosses isolation boundaries on every hibernate/wake cycle.
- **Runtime concurrency diagnostics under test** catch races static analysis misses — and
  `BrowserCoreTests` already drives exactly those paths.

Migrate **module by module** via upcoming-feature flags. `QwaveSupport` and `Persistence` first:
small, leaf-ward, well tested.

→ [Platform Baseline](#part-iii--platform-baseline) · [Concurrency & Runtime](#04--concurrency--runtime)

### 4. 🛡️ 51 rules is a demonstration, not a blocklist

`Shields/Resources/starter-blocklist.json` is a curated **51-rule** `WKContentRuleList`. EasyList
is tens of thousands. That gap is a *sourcing* problem, not an engineering one — nobody
hand-writes rule JSON at scale.

**SafariConverterLib** converts filter-list syntax into the JSON `WKContentRuleList` already
consumes. Run it at build time and the shipped app gains a production-scale rule set with
**zero new runtime dependencies** and no architectural change:

```
EasyList / AdGuard Base ─► SafariConverterLib ─► starter-blocklist.json ─► Shields
      (upstream)            (build machine)         (committed)            (runtime)
```

The gate is licensing, not engineering — see [Open Questions](#part-vi--open-questions).

→ [SafariConverterLib](01-webkit-browser-engine/safari-converter-lib.md)

### 5. 📊 The energy claim is asserted, not measured — and the obvious tool cannot measure it

The README's headline claim is memory and battery optimisation via `TabHibernator`.
`EnergyGovernorTests` and `HibernationControllerTests` verify the **logic** — that the right
decisions are made. Nothing verifies the **outcome**: that memory is reclaimed, or how much.

The trap: adopting a benchmark package and assuming it covers this. **It cannot.** `TabHibernator`
reclaims memory by tearing down `WKWebView` instances, and that memory lives in **WebKit's
content processes** — other processes an in-process benchmark cannot see. Green benchmarks
alongside a regressed product is worse than no measurement.

The strategy has to be layered: `package-benchmark` for in-process work (parsing, SQLite, rule
compilation); `XCTMemoryMetric` and Instruments for the whole-system memory claim.

→ [Performance & Energy](#11--performance--energy)

### 6. 🧠 On-device AI is now affordable and structurally private — with four hard constraints

M5 puts a Neural Accelerator in every GPU core; Apple's own MLX measurements show **3.3×–4.06×
faster time-to-first-token** versus M4. A browser that ships a *cloud* AI feature has undone its
own privacy story; one that runs the same feature entirely on-device has strengthened it.

**Foundation Models is the correct first step** — no download, no storage management, no model
updates to own, three lines of integration. WWDC26's provider protocol means MLX can later serve
as a backend behind the *same* `LanguageModelSession` API, so this choice does not foreclose the
expensive path.

Four non-negotiables, or it does not ship: **optional** (never a launch dependency),
**local** (no egress), **energy-aware** (consults `EnergyGovernor`), **explicit** (user-invoked,
never speculative).

→ [On-Device AI](#02--on-device-ai--ml)

---

## Recommended sequence

Ordered by leverage and dependency, not by category.

### Phase 0 — Unblocks everything else

| # | Action | Why |
|---|--------|-----|
| 0.1 | Obtain a Developer ID certificate | Gates 0.2–0.4 and the entire VPN feature |
| 0.2 | Sign app + `PacketTunnel.systemextension` via `project.yml` | Gatekeeper, and system extension approval |
| 0.3 | Notarise + staple in `release.yml` | Clean launch without user workarounds |
| 0.4 | Add [Sparkle](12-distribution-updates/sparkle.md) with an EdDSA-signed appcast | Security fixes can actually reach users |
| 0.5 | Pin the Xcode version in CI | Toolchain changes stop arriving without a commit |

### Phase 1 — Correctness and quality gates (cheap, high confidence)

| # | Action | Verdict |
|---|--------|---------|
| 1.1 | Write failing tests for the IDN/backslash cases in `ShieldsPolicyTests` **before** adding a dependency | — |
| 1.2 | Adopt [WebURL](01-webkit-browser-engine/weburl.md) behind a `canonicalHost` shim in `QwaveSupport` | 🟢 |
| 1.3 | Add [swift-format](09-build-tooling/swift-format.md) + one isolated reformat commit + `.git-blame-ignore-revs` | 🟢 |
| 1.4 | Migrate table-driven suites to [swift-testing](10-testing-quality/swift-testing.md) (`ShieldsPolicyTests`, `OmniboxParserTests` first) | 🟢 |
| 1.5 | Swap `TabManager`'s array+index for [`OrderedDictionary`](04-concurrency-runtime/swift-collections.md) | 🟢 |

### Phase 2 — Structural improvements

| # | Action | Verdict |
|---|--------|---------|
| 2.1 | Migrate `QwaveSupport` and `Persistence` to Swift 6.2 concurrency via upcoming-feature flags | — |
| 2.2 | Adopt [GRDB](05-persistence-data/grdb.md) in `Persistence`, `HistoryStore` first; verify migration against a real 0.1.0 database | 🟢 |
| 2.3 | Add [swift-snapshot-testing](10-testing-quality/swift-snapshot-testing.md) for `TunnelSessionConfig` | 🔵 |
| 2.4 | Run [Periphery](09-build-tooling/periphery.md) locally, tune `.periphery.yml`, then add report-only to CI | 🔵 |
| 2.5 | Benchmark `OmniboxParser` with [package-benchmark](11-performance-energy/package-benchmark.md); measure hibernation separately with `XCTMemoryMetric` | 🔵 |

### Phase 3 — Feature work

| # | Action | Verdict |
|---|--------|---------|
| 3.1 | License review on [SafariConverterLib](01-webkit-browser-engine/safari-converter-lib.md); if clear, build `Tools/BlocklistBuilder` | 🔵 |
| 3.2 | Pin the Mullvad API with [swift-certificates](07-security-crypto-vpn/swift-certificates.md) — **design pin rotation first** | 🔵 |
| 3.3 | Add app-scoped [KeyboardShortcuts](08-ui-appkit-swiftui/keyboard-shortcuts.md) — burner tab, container switch, shield toggle | 🔵 |
| 3.4 | Prototype readability extraction (backend-independent), then [Foundation Models](02-on-device-ai/foundation-models.md) summarisation | 🔵 |
| 3.5 | Test `_WKFeature` SPI reachability from [`WebPage.Configuration`](01-webkit-browser-engine/webkit-for-swiftui.md) — gates the whole WebKit-for-SwiftUI path | 🟢 |

---

## Verdict matrix — all 40 packages

### 🟢 Adopt — 10

| Package | Version | License | Category | Qwave module | Rationale |
|---------|---------|---------|----------|--------------|-----------|
| [WebKit for SwiftUI](01-webkit-browser-engine/webkit-for-swiftui.md) | macOS 26+ | Apple SDK | 01 | `BrowserCore`, `QwaveApp` | Gated + additive; `WebPage` is `@Observable`, subsumes 3 hand-rolled files |
| [WebURL](01-webkit-browser-engine/weburl.md) | 0.4.2 | Apache 2.0 | 01 | `Shields`, `OmniboxParser` | Closes a real shield-bypass surface; contain behind a shim (pre-1.0) |
| [swift-collections](04-concurrency-runtime/swift-collections.md) | 1.6.0 | Apache 2.0 | 04 | `TabManager` | `OrderedDictionary` *is* the tab bar's data shape; 1.6.0 adds reorder ops |
| [GRDB](05-persistence-data/grdb.md) | 7.11.1 | MIT | 05 | `Persistence` | `ValueObservation` + `DatabasePool` + `DatabaseMigrator`; replaces the riskiest hand-written code |
| [swift-crypto](07-security-crypto-vpn/swift-crypto.md) | 4.5.1 | Apache 2.0 | 07 | `DeviceKeyManager` | CryptoKit now; swift-crypto as the pre-approved PQ escape hatch. **Not the 5.0 beta** |
| [WireGuardKit](07-security-crypto-vpn/wireguardkit.md) | pinned `2fec12a6` | MIT | 07 | `PacketTunnel` | Already integrated, and correctly — commit pin + process isolation |
| [XcodeGen](09-build-tooling/xcodegen.md) | 2.46.0 | MIT | 09 | build | Already integrated; 2.46 traits support covers the one forward-looking need |
| [swift-format](09-build-tooling/swift-format.md) | 603.0.0 | Apache 2.0 | 09 | CI | First-party, ships with Xcode, settles formatting permanently |
| [swift-testing](10-testing-quality/swift-testing.md) | Swift 6.3.2 | Apache 2.0 | 10 | all test targets | Parameterised tests transform the table-driven security suites; coexists with XCTest |
| [Sparkle](12-distribution-updates/sparkle.md) | 2.9.5 | MIT-style | 12 | `QwaveApp` | The standard; blocked on signing, which is the actual finding |

### 🔵 Trial — 10

| Package | Version | License | Category | Condition |
|---------|---------|---------|----------|-----------|
| [SafariConverterLib](01-webkit-browser-engine/safari-converter-lib.md) | 4.3.0 | LGPL-3.0 † | 01 | **Build-time only**, pending license review; never linked into the app |
| [MLX Swift](02-on-device-ai/mlx-swift.md) | 0.31.6 | MIT | 02 | Behind a SwiftPM trait, `EnergyGovernor`-gated, only if Foundation Models proves insufficient |
| [Foundation Models](02-on-device-ai/foundation-models.md) | macOS 26+ | Apple SDK | 02 | Build readability extraction first — that is the hard, backend-independent part |
| [swift-async-algorithms](04-concurrency-runtime/swift-async-algorithms.md) | 1.1.5 | Apache 2.0 | 04 | **After** the Swift 6.2 migration; start with the omnibox debounce |
| [swift-certificates](07-security-crypto-vpn/swift-certificates.md) | 1.19.4 | Apache 2.0 | 07 | Mullvad API pinning only. Design pin rotation before implementing |
| [KeyboardShortcuts](08-ui-appkit-swiftui/keyboard-shortcuts.md) | 3.0.1 | MIT | 08 | **App-scoped only** — never request Accessibility/Input Monitoring |
| [Defaults](08-ui-appkit-swiftui/defaults.md) | 9.0.9 | MIT | 08 | UI state only. `SettingsStore` stays on SQLite |
| [Periphery](09-build-tooling/periphery.md) | 3.8.0 | MIT | 09 | Report-only first; tune against the `_WKFeature` reflection pattern |
| [swift-snapshot-testing](10-testing-quality/swift-snapshot-testing.md) | 1.19.4 | MIT | 10 | Start with `TunnelSessionConfig`; snapshot diffs reviewed like code |
| [package-benchmark](11-performance-energy/package-benchmark.md) | 1.36.2 | Apache 2.0 | 11 | `OmniboxParser` first. **Cannot measure the hibernation claim** |

† License stated from knowledge, not fetched — see [Open Questions](#part-vi--open-questions).

### 🟡 Assess — 13

| Package | Version | Category | Why it stalls |
|---------|---------|----------|---------------|
| [adblock-rust](01-webkit-browser-engine/adblock-rust.md) | untagged | 01 | Requires owning the network stack; Qwave deliberately does not. Rust toolchain cost |
| [mlx-swift-examples](02-on-device-ai/mlx-swift-examples.md) | 2.29.1 | 02 | Reference material, not a library. Vendor with provenance; do not depend |
| [swift-transformers](02-on-device-ai/swift-transformers.md) | 1.3.3 | 02 | Two decision levels down; `Hub` is a runtime network dependency |
| [Metal 4](03-gpu-metal-compute/metal-4.md) | macOS 26+ | 03 | Understand it, do not render with it. One idea: GPU pressure → `EnergyGovernor` |
| [Alloy](03-gpu-metal-compute/alloy.md) | 0.18.2 | 03 | No current GPU workload; Core Image wins for thumbnails |
| [swift-subprocess](04-concurrency-runtime/swift-subprocess.md) | 1.0.0 | 04 | Build tooling only. `Qwave.app` does not spawn subprocesses |
| [SQLiteData](05-persistence-data/sqlite-data.md) | 1.10.0 | 05 | Flagship feature is CloudKit sync — which the product must refuse |
| [swift-structured-queries](05-persistence-data/swift-structured-queries.md) | 0.36.0 | 05 | Right idea, pre-1.0, in the module holding user data. Revisit at 1.0 |
| [swift-http-types](06-networking/swift-http-types.md) | 1.6.0 | 06 | Good types, one consumer. Revisit if `VPNKit` grows (Stage B) |
| [swift-navigation](08-ui-appkit-swiftui/swift-navigation.md) | 2.11.0 | 08 | Adopt the *pattern* free; AppKit module maturity unverified |
| [SwiftUI Introspect](08-ui-appkit-swiftui/swiftui-introspect.md) | 27.0.0-beta.2 | 08 | Qwave already owns the AppKit layer — it has a better escape hatch |
| [SwiftLint](09-build-tooling/swiftlint.md) | 0.65.0 | 09 | Correctness rules yes (`weak_delegate`), style rules no. After swift-format |
| [Tuist](09-build-tooling/tuist.md) | 1.256.4 | 09 | Caching value scales with module count. Qwave has 6 |

### 🔴 Hold — 7

| Package | Category | Reason |
|---------|----------|--------|
| [WhisperKit](02-on-device-ai/whisperkit.md) | 02 | Excellent package, wrong product. System dictation covers the only credible use case at zero cost |
| [MetalPetal](03-gpu-metal-compute/metalpetal.md) | 03 | Qwave displays web content; it does not process video |
| [swift-atomics](04-concurrency-runtime/swift-atomics.md) | 04 | Superseded by stdlib `Synchronization`. Qwave should need neither |
| [SwiftNIO](06-networking/swift-nio.md) | 06 | **Leak surface.** `URLSession` follows system routing when the tunnel is up; NIO does not |
| [AsyncHTTPClient](06-networking/async-http-client.md) | 06 | Same argument. `URLSession` is not a fallback here — it is better |
| [mullvadvpn-app](07-security-crypto-vpn/mullvadvpn-app.md) | 07 | **GPL-3.0 in an MIT app.** Invaluable as a reference, prohibited as a dependency |
| [swift-build](09-build-tooling/swift-build.md) | 09 | Infrastructure, not a dependency. It is the engine under tools already in use |

**A 🔴 Hold is not a quality judgement.** Most are excellent packages that do not belong in a
browser shell. The reasoning is recorded so the question closes rather than recurring.

---

# Part II · Cross-Cutting Themes

Five arguments recurred across categories and drove more verdicts than any package-specific
consideration. They are worth stating as standing rules.

## 1. Qwave does not own the network stack — and must not start

WebKit handles all web content networking in its own process, with its own TLS, cookies, cache,
and proxy configuration. Qwave's own traffic is `MullvadAPIClient`'s REST calls and
`BlocklistUpdater`'s file download.

The decisive property is not simplicity — it is **leak-proofing**. `URLSession` uses the system
network stack, so when the WireGuard tunnel is up, app traffic follows the system routing table
automatically, including proxy settings, ATS, and DNS. A NIO-based client opens its own sockets
on its own event loops; making that reliably tunnel-aware is work, and failing at it means
**traffic leaking outside the VPN**.

> **Rule:** all app-level networking goes through `URLSession`. Any proposal for a different HTTP
> client must first answer how it stays inside the tunnel.

Drove: [SwiftNIO](06-networking/swift-nio.md) 🔴 · [AsyncHTTPClient](06-networking/async-http-client.md) 🔴 · [adblock-rust](01-webkit-browser-engine/adblock-rust.md) 🟡

## 2. WebKit owns the GPU — a second consumer competes with the renderer

Compositing, rasterisation, video decode, WebGL, and WebGPU all run inside WebKit's processes.
Any GPU work Qwave submits delays WebKit's, and the user experiences that as page performance.

The inversion worth noting: the *legitimate* GPU-adjacent opportunity is **observation, not
submission**. `EnergyGovernor` maps `EnergyConditions` — thermal state, low-power mode, window
occlusion — to a tier. A tab running sustained WebGPU work drains battery in a way none of those
three reveals directly; thermal state catches it only after the machine has heated up. Sampling
GPU counters costs no GPU time, and the governor's pure-function design makes the new input a
small, testable change. Caveat: the counters are advisory and reflect only the current process,
so validate against real battery behaviour before letting them drive hibernation.

Drove: [Metal 4](03-gpu-metal-compute/metal-4.md) 🟡 · [Alloy](03-gpu-metal-compute/alloy.md) 🟡 · [MetalPetal](03-gpu-metal-compute/metalpetal.md) 🔴

## 3. Every dependency is attack surface in a sovereign browser

This is not a general preference for minimalism — it is specific to the product's claim. A
browser whose pitch is "you can verify what this does" pays a real cost for each transitive
dependency an auditor must read.

Consequences that showed up repeatedly:

- **Prefer platform frameworks.** CryptoKit over swift-crypto until a primitive demands otherwise.
  `Synchronization` over swift-atomics. Core Image over Alloy. System dictation over WhisperKit.
- **Prefer build-time over runtime.** SafariConverterLib's output ships; the converter does not.
- **Count the stack, not the package.** GRDB + swift-structured-queries + SQLiteData is three
  dependencies in the module holding user data, where one does most of the job.
- **Watch for runtime egress.** `Hub` in swift-transformers, update checks in Sparkle. Both may be
  acceptable — but only as disclosed, user-controllable actions.

## 4. Energy-first is a constraint, not a slogan

`TabHibernator` and `EnergyGovernor` are the product's differentiation, which makes anything that
keeps a core hot a design conflict rather than a performance detail.

It cut both ways in this research:

- **Against** — MLX inference is the most power-hungry thing this app could do, and its
  allocations compete directly with the WebKit content processes `TabHibernator` exists to
  reclaim. NIO event loop threads work against keeping cores idle.
- **For** — `debounce`/`throttle` reduce wakeups on the omnibox and blocklist paths.
  `OrderedDictionary` removes a redundant index. `DatabasePool`'s bounded connections cap the
  page cache competing with WebKit for unified memory.

> **Rule:** anything discretionary consults `EnergyGovernor` and runs only at the `.normal` tier.
> One policy surface, not two.

`EnergyGovernor` is a **pure enum** — `tier(for: EnergyConditions)` then
`policy(for:baseHibernationTimeout:)`, with the app layer owning sampling and a single coalesced
timer. That statelessness is the best property of the current design: every gate proposed in this
research is testable by constructing conditions and asserting a tier. **Preserve it** — extend
`EnergyConditions` with new inputs (GPU pressure, memory pressure) rather than giving the governor
state of its own.

## 5. Licensing is a gate, not paperwork

Two packages were decided primarily on licence, and both are cases where the code is excellent:

- **mullvadvpn-app (GPL-3.0)** — the reference implementation for every hard problem in `VPNKit`,
  in Swift, in production. Read for understanding; implement independently from Mullvad's
  published API documentation. "We reworded it" is not a defence for a close transliteration.
- **SafariConverterLib (copyleft)** — viable only under strict build-time separation, where the
  tool is never distributed and only its JSON output ships.

Filter lists carry their own terms (typically CC BY-SA / GPL) independent of the converter, so
redistributing generated rules needs the same scrutiny.

> **Rule:** GPL/LGPL-linked code cannot ship inside `Qwave.app`. It may be used offline, at build
> time, to generate resources.

---

# Part III · Platform Baseline

The floor everything above assumes.

## Operating system

| Release | Status 2026-08-12 |
|---------|-------------------|
| macOS 26 "Tahoe" | Current shipping. First Apple Silicon-only major; Metal 4 baseline |
| macOS 27 "Golden Gate" | Beta since WWDC26 (dev beta 2026-06-08, public beta 2026-07-13); GA expected ~September 2026 |

**Qwave targets macOS 14.0 — three majors behind.** This is the single largest constraint in the
research: WebKit for SwiftUI, Foundation Models, and Metal 4 all require macOS 26+.

**Recommendation:** hold the macOS 14 floor for the core browser; gate every macOS 26+ capability
behind `#available` in optional modules. Qwave already proves it can do this safely —
`FeatureFlags/FeatureFlagSafety.swift` is exactly this pattern applied to Safari SPI.

## Toolchain

| Tool | Version | Note |
|------|---------|------|
| Swift | **6.4** | Ships in Xcode 27; backwards compatible with 6.x, no breaking changes |
| Swift | **6.3** | Previous stable; `swift-testing` and `swift-build` tag against it |
| Swift | **6.2** | "Approachable Concurrency" — the release that matters for Qwave |
| Xcode | **27** (beta 4, 2026-07-20) | **Apple Silicon only**; requires macOS 26.4+ to run |
| Xcode | **26** | Current stable |

SwiftPM notes: `swift package show-traits` makes traits discoverable; XcodeGen 2.46 added trait
support for remote and local package references, so trait-gating (the
[MLX](02-on-device-ai/mlx-swift.md) proposal) works end to end today. Prebuilt swift-syntax
binaries materially cut clean-build time for macro-using packages — which is every modern package
here.

## Silicon

| Chip | Unified memory | Bandwidth |
|------|----------------|-----------|
| M5 | up to 32 GB | — |
| M5 Pro | up to 64 GB | up to 307 GB/s |
| M5 Max | up to 128 GB | up to 614 GB/s |

The architectural change: **a Neural Accelerator in every GPU core**. Apple claims up to 4× AI
performance versus M4 Pro/Max, 8× versus M1. MLX's M5 acceleration path requires **macOS 26.2+**.

For a browser, the relevant consequence is not speed but **memory topology**: GPU memory pressure
and system memory pressure are the same pressure. A page allocating large WebGPU buffers competes
with `WKWebView` content processes and with anything MLX holds — which is why the AI constraints
in finding 6 are architectural rather than cautious.

## Version-pinning stance

| Concern | Position |
|---------|----------|
| Swift language mode | 5.10 → 6.2 module-by-module via upcoming-feature flags. Never one flip |
| Deployment target | Hold macOS 14 for core; gate macOS 26+ behind `#available` |
| Dependency count | Every dependency is auditor surface. Platform > Apple-maintained > audited third party |
| WireGuard pin | Stays at `2fec12a6…` until the tunnel is tested end-to-end against a newer revision |
| CI toolchain | Pin the Xcode version. Tracking `latest` lets build behaviour change without a commit |

---

# Part IV · Deep Research by Category

## 01 · WebKit & Browser Engine

The layer Qwave *is*. Nothing here is optional — these touch `BrowserCore`, `Shields`, and
`FeatureFlags` directly.

**[WebKit for SwiftUI](01-webkit-browser-engine/webkit-for-swiftui.md)** · macOS 26+ · 🟢 Adopt (gated)
First-party SwiftUI surface for WebKit, replacing the `NSViewRepresentable`-wrapping-`WKWebView`
pattern. `WebView` is the view; **`WebPage` is an `@Observable` class** for the content itself,
designed for Swift concurrency rather than retrofitted onto delegates. It subsumes three
hand-rolled Qwave files: `NavigationCoordinator` (observable navigation state),
`FindInPageController` and `FindBarView` (the `findNavigator` modifier). Container isolation
carries over — `WebPage.Configuration` still takes a `WKWebsiteDataStore`.
**The gating unknown:** whether `WebPage.Configuration` exposes the `_WKFeature` reflection hook
`FeatureFlags` depends on. If not, this can never be a *replacement*, only an alternative. Cheap
to test, and it should be tested first.
*Suggested spike:* render the Settings preview pane with `WebView` — real content, zero blast radius.

**[WebURL](01-webkit-browser-engine/weburl.md)** · 0.4.2 · Apache 2.0 · 🟢 Adopt
WHATWG URL Standard in pure Swift, with IDN support, host-parsing APIs, and Foundation interop.
The highest-value, lowest-risk package in the folder — see [finding 2](#2--foundation-url-and-webkit-disagree-about-what-a-host-is--and-that-is-a-shield-bypass).
`OmniboxParser` also has a second job it serves: the URL-vs-search-query decision, which every
browser tunes and which needs spec-accurate parsing underneath.
*Risks:* pre-1.0 API churn (contain behind a `canonicalHost` shim in `QwaveSupport`); single
maintainer; two URL types coexisting — convert at the boundary, deliberately, in one place.
*First step:* write the failing test before adding the dependency.

**[SafariConverterLib](01-webkit-browser-engine/safari-converter-lib.md)** · 4.3.0 · copyleft † · 🔵 Trial
AdGuard's Swift converter from filter-list syntax to `WKContentRuleList` JSON — handling rule
dedup, `$domain`/`$third-party` modifier mapping, regex translation to WebKit's supported subset,
and the platform rule-count ceiling. See [finding 4](#4--51-rules-is-a-demonstration-not-a-blocklist).
Shape: a separate `Tools/BlocklistBuilder` package, never in `Packages/QwaveKit`; generated JSON
committed and reviewed in the diff; validated by existing `RuleListCompileTests`.
*Risks:* **licensing is the decision** — confirm the exact terms before writing code, and never
link it into the app. Filter lists carry their own licences. WebKit rule limits mean output must
be validated — a silently truncated rule set is worse than a small honest one. Large lists take
real time and memory to compile; do it off the main thread and cache.

**[adblock-rust](01-webkit-browser-engine/adblock-rust.md)** · untagged · MPL-2.0 · 🟡 Assess
The actual Brave engine — full modifier vocabulary (`$redirect`, `$removeparam`, `$csp`, cosmetic
filtering with scriptlets) that `WKContentRuleList` cannot express. Understanding **why it does
not fit** is more useful than adopting it: in-process matching requires seeing every request,
which means owning the network stack. Brave forks Chromium and does; Qwave is WebKit-native and
does not. For build-time rule generation, SafariConverterLib is already Swift and already targets
this output format — it wins on every axis.
*Revisit if* `PacketTunnel` ever grows DNS- or packet-level filtering, at which point the engine
would live in the extension. That is Stage C territory.

## 02 · On-Device AI & ML

**The sovereignty argument:** a browser shipping a cloud AI feature has undone its own privacy
story; one running the same feature entirely on-device has strengthened it. That is the only
reason this category belongs in browser research.

**The two paths:**

| | Foundation Models | MLX Swift |
|--|-------------------|-----------|
| Model | Apple's ~3B, ~2-bit quantised | Any model you convert |
| Download | **None** — part of the OS | 1–20 GB, plus a download subsystem |
| Floor | macOS 26 + Apple Intelligence hardware | macOS 26.2+ for M5 accelerators |
| Storage / updates | Apple's problem | Yours |
| Integration | Three lines | A real subsystem |

**[Foundation Models](02-on-device-ai/foundation-models.md)** · macOS 26+ · 🔵 Trial
`import FoundationModels`, create a `LanguageModelSession`, call `respond`. The ~3B model at ~2
bits/weight is genuinely adequate for summarising visible article text — the one AI feature that
clearly belongs in a privacy-first browser. It is shared across the system, so it is not per-app
resident memory, which matters enormously against WebKit's working set.
**WWDC26 removed the framework's one hard rule:** a public provider protocol means any LLM can
back `LanguageModelSession`, so writing against this API once keeps the backend swappable.
*Risks:* macOS 26 floor **plus** a hardware floor (not every Apple Silicon Mac supports Apple
Intelligence) — the feature must vanish cleanly when absent, not error. ~3B is small: scope the
feature to what it can do. No control over model updates, so keep prompts simple. **The real work
is content extraction** — a readability-style `WKUserScript` producing clean article text is
harder than the inference call, and it is backend-independent. Build it first.

**[MLX Swift](02-on-device-ai/mlx-swift.md)** · 0.31.6 · MIT · 🔵 Trial
Apple's array framework for ML on Apple Silicon, built on unified memory with lazy evaluation.
Three plausible Qwave features, descending in value: page summarisation, local omnibox reranking
over `HistoryStore`, heuristic shield assist for unknown hosts.
*Risks:* **model distribution is bigger than the inference code** — download flow, integrity
verification, storage management, updates. **Memory contention with WebKit** is the direct
conflict: a 7B model at 4-bit is ~4 GB resident, competing for the pool `TabHibernator` exists to
reclaim. Sustained GPU inference is the most power-hungry thing this app could do. Pre-1.0 with a
few-weeks cadence — pin exactly.
*Verdict rationale:* ship on Foundation Models first; swap the backend only if Apple's model
proves insufficient. That ordering gets the feature out at a fraction of the cost and keeps the
expensive path open.

**[mlx-swift-examples](02-on-device-ai/mlx-swift-examples.md)** · 2.29.1 · MIT · 🟡 Assess
Apple's companion repo — model implementations and runnable examples. **Reference material, not a
dependency.** The pieces worth reading before any MLX integration: weight loading and
quantisation, tokeniser integration, KV cache management, async token streaming into SwiftUI, and
`MLX.GPU.set(cacheLimit:)` — the last being how you cap MLX's footprint to coexist with WebKit.
If needed, vendor a specific model implementation with a provenance header and MIT notice.

**[swift-transformers](02-on-device-ai/swift-transformers.md)** · 1.3.3 · Apache 2.0 · 🟡 Assess
`Tokenizers`, `Hub`, `Generation`. Relevant only in the MLX branch — Foundation Models handles
tokenisation internally, which is one more reason that path is cheaper than it first appears.
Tokenisation is the underestimated part: getting it subtly wrong produces plausible, quietly
degraded output with no crash and no error. **`Hub` is the problem child** — it solves model
distribution by making the browser fetch from a third-party service at runtime. If used at all,
it must be explicit, disclosed, and user-initiated.

**[WhisperKit](02-on-device-ai/whisperkit.md)** · 1.1.0 · MIT · 🔴 Hold
Well-engineered on-device speech-to-text (1.1.0 cut peak memory 70%+ for 3-hour audio). Every
plausible browser use case is already solved: **system dictation** works in every text field
including `OmniboxField`; pages provide their own captions; VoiceOver is the other direction.
The cost is not just a dependency — **adding microphone access to `Qwave.entitlements` weakens
the sovereignty claim for a feature nobody asked for.**

## 03 · GPU, Metal & Compute

Mostly Assess and Hold, which is the correct outcome — see
[cross-cutting theme 2](#2-webkit-owns-the-gpu--a-second-consumer-competes-with-the-renderer).

**[Metal 4](03-gpu-metal-compute/metal-4.md)** · macOS 26+ · 🟡 Assess
Ground-up redesign, **Apple Silicon only** — the same line Qwave already draws. The headline is
ML/graphics convergence on one timeline: **`MTLTensor`** as an API and shading-language type,
**`MTL4MachineLearningCommandEncoder`** running whole networks alongside draws, and **Shader ML**
embedding inference inside your own shaders. 4- and 8-bit integer support landed in a macOS 26
update, widening in 27.
Reaches Qwave indirectly — through WebKit's WebGPU implementation and through MLX.
**The one direct opportunity:** GPU utilisation as an `EnergyGovernor` input. Observation, not
submission; costs no GPU time; feeds the decision `TabHibernator` already makes. Caveat:
`currentAllocatedSize` reflects the current process, not WebKit's content processes — treat it as
one weak signal and validate against real battery behaviour.

**[Alloy](03-gpu-metal-compute/alloy.md)** · 0.18.2 · MIT · 🟡 Assess
Thin ergonomics layer over Metal — command buffer management, texture descriptors, threadgroup
sizing. The one plausible use is a visual tab switcher compositing `TabHibernator` snapshots. Even
then the honest comparison is against **Core Image**, which is GPU-backed, Apple-tuned,
dependency-free, and very hard to lose to for thumbnail work. Predates Metal 4; currency unverified.

**[MetalPetal](03-gpu-metal-compute/metalpetal.md)** · 1.25.2 · MIT · 🔴 Hold
GPU image/video processing with a render graph. Qwave **displays** web content; it does not
process it. WebKit owns decode, colour management, compositing, and video. The render graph is
designed to saturate the GPU — in a browser, saturating the GPU starves the renderer.

## 04 · Concurrency & Runtime

**The biggest item is not a package** — it is the Swift 6.2 migration, see
[finding 3](#3--swift-62-approachable-concurrency-would-simplify-the-tab-lifecycle). The package
list is short because the stdlib absorbed most of this category: `Mutex` and `Atomic` live in
`Synchronization`; structured concurrency and actors are language features.

**[swift-collections](04-concurrency-runtime/swift-collections.md)** · 1.6.0 · Apache 2.0 · 🟢 Adopt
The cleanest fit in the folder. `TabManager` maintains tabs that are **ordered** (the tab bar) and
**unique** (one per identity), with frequent keyed lookup (`TabHibernator` waking a tab,
`NavigationCoordinator` routing an event). An array gives O(n) lookup; a dictionary loses order;
maintaining both is how "tab bar and tab model disagree" bugs get written.
`OrderedDictionary<TabID, Tab>` is exactly that shape — and **1.6.0's `move(indices:to:)` is tab
drag-and-drop**. Also: `Deque` for back/forward history (O(1) both ends), `BitSet` for per-host
shield flags across thousands of hosts.
*Migration:* `TabManagerTests` already covers ordering and lookup, so the refactor is verifiable.
Import `OrderedCollections`, not the `Collections` umbrella.

**[swift-async-algorithms](04-concurrency-runtime/swift-async-algorithms.md)** · 1.1.5 · Apache 2.0 · 🔵 Trial
Three concrete applications: **`debounce`** on omnibox input (hand-rolled debouncing with `Task`
cancellation is a classic race source — a cancelled task that already scheduled its continuation,
a stale result arriving after a newer one); **`throttle`/`chunked`** on `BlocklistUpdater`, since
recompiling a `WKContentRuleList` is expensive; **`combineLatest`** for `VPNStatusItem`, which
must reflect tunnel status, relay, and account together.
Energy angle: reducing wakeups is the whole point on a heterogeneous-core platform.
*Sequencing:* adopt **after** the Swift 6.2 migration — these operators are most ergonomic under
the new model, and adopting them on the 5.10 `targeted` stance means fighting sendability
diagnostics the newer model removes. Watch cancellation propagation when a tab closes mid-flight.

**[swift-subprocess](04-concurrency-runtime/swift-subprocess.md)** · 1.0.0 · Apache 2.0 · 🟡 Assess
Modern `Foundation.Process` replacement, source-stable at 1.0. Zero value in the app — the VPN
uses `NETunnelProviderManager`, extension activation uses `OSSystemExtensionManager`, file opening
uses `NSWorkspace`. Useful only if `Tools/BlocklistBuilder` is built and grows past a shell script.
> **Rule:** `Qwave.app` does not spawn subprocesses. If a feature seems to need one, that is a
> design smell to investigate, not a dependency to add.

**[swift-atomics](04-concurrency-runtime/swift-atomics.md)** · 1.x · Apache 2.0 · 🔴 Hold
Superseded by stdlib `Synchronization` (`Atomic`, `Mutex`) with no dependency and better Swift 6
sendability integration. The stronger point: **Qwave should need neither.** Actors and structured
concurrency cover coordination at tab-lifecycle granularity — microseconds apart, not nanoseconds.
*Apple Silicon note worth keeping:* **arm64 has a weaker memory model than x86_64.** Hand-written
lock-free code that works on Intel through stronger implicit ordering can fail here. That argues
for `Mutex` generally, not just against this package.

## 05 · Persistence & Data

`Persistence` is **raw SQLite** — `SQLiteDatabase.swift` wrapping the C API in WAL mode, with four
stores on top. Right call for v0.1.0: fast, dependency-free, and "I can read every line that
touches user data" has real value for a sovereign browser. It also means hand-maintaining
statement lifecycle, parameter binding, decoding, migration ordering, connection lifetime, and WAL
checkpointing — each a place where a subtle bug means corrupted history.

**[GRDB](05-persistence-data/grdb.md)** · 7.11.1 · MIT · 🟢 Adopt
The same idea done comprehensively, with a decade of production hardening.
- **`ValueObservation` is decisive.** `LibraryWindow` displays history and bookmarks written by
  `NavigationCoordinator` on every page load. Keeping it current is otherwise a manual refresh
  (stale UI) or a hand-rolled notification layer (a bug farm). GRDB observes at the SQLite level,
  so it sees every write regardless of origin.
- **`DatabasePool`** realises WAL's actual promise — concurrent readers with one writer — and is
  the piece most likely to be subtly wrong hand-rolled, because the failure mode is not a crash
  but rare `SQLITE_BUSY` under load.
- **`DatabaseMigrator`** matters because `SessionStore` restores sessions across launches; a
  botched migration loses the user's tabs.
*Apple Silicon:* SQLite's page cache competes with WebKit for unified memory, so `DatabasePool`'s
bounded connections are a footprint feature, not just a correctness one.
*Risks:* first runtime dependency in the user-data path; four stores to migrate; keep GRDB types
out of `BrowserCore` entirely. **Verify migration against a real 0.1.0 database** — users have
real history.

**[SQLiteData](05-persistence-data/sqlite-data.md)** · 1.10.0 · MIT · 🟡 Assess
SwiftData replacement on GRDB, with `@FetchAll`-style property wrappers. Two things weaken it
here: **its flagship feature is CloudKit sync**, which is precisely the behaviour a sovereign
browser exists to avoid — adopting a library for a capability you must deliberately disable is
weak justification. And **Qwave is an AppKit shell**; SwiftUI is two windows, so the property
wrappers have limited reach. Also triples the dependency count in the user-data module.
*If ever adopted:* add a test asserting no CloudKit container is configured. That is a sovereignty
guarantee, not a preference.

**[swift-structured-queries](05-persistence-data/swift-structured-queries.md)** · 0.36.0 · MIT · 🟡 Assess
Macro-driven compile-time-checked SQL. The bug class it eliminates is real and Qwave is exposed to
it across four stores — a column typo in a SQL string ships fine and fails at runtime.
`jsonArrayInsert` (0.36.0) is incidentally apt for `SessionStore`'s document-shaped tab state.
*But:* pre-1.0 with active API churn, in the module where breakage means lost user history.
GRDB's own query interface provides substantial type safety at 7.x maturity — the better
risk-adjusted trade today. **Revisit at 1.0.**

## 06 · Networking & Protocols

Mostly Hold, by design — see
[cross-cutting theme 1](#1-qwave-does-not-own-the-network-stack--and-must-not-start).

**[swift-http-types](06-networking/swift-http-types.md)** · 1.6.0 · Apache 2.0 · 🟡 Assess
Apple's transport-independent HTTP vocabulary: `HTTPRequest`, `HTTPFields`, `HTTPField.Name`,
`HTTPResponse.Status`. The crucial property is Apple's own **`URLSession` integration** —
adopting the vocabulary does not mean adopting a transport, which preserves the leak-proofing
argument. Typed field names catch header typos at compile time; `HTTPResponse.Status` is a real
type rather than an `Int` compared against magic numbers. `MockURLProtocol` in `VPNKitTests`
survives unchanged.
*But:* one consumer (`MullvadAPIClient`). A small hand-rolled `enum HeaderName` captures most of
the benefit with no dependency. **Revisit if `VPNKit` grows** — Stage B would qualify.

**[SwiftNIO](06-networking/swift-nio.md)** · 2.101.3 · Apache 2.0 · 🔴 Hold
Excellent, and built for servers. The argument against is not absence of benefit but **active
harm**: `URLSession` follows the system routing table when the tunnel is up; NIO opens its own
sockets on its own event loops, and getting that wrong leaks traffic outside the VPN. The tunnel
itself is not a NIO use case either — `NEPacketTunnelProvider` operates at the packet level, below
NIO's abstraction. NIO event loop threads also work against `EnergyGovernor`'s purpose.

**[AsyncHTTPClient](06-networking/async-http-client.md)** · 1.36.0 · Apache 2.0 · 🔴 Hold
Same argument. Note that its 1.36.0 proxy-header support is a reminder that **proxy handling is
something you implement and maintain here**, whereas `URLSession` picks up the system proxy
configuration — including whatever the tunnel sets — without code. The one plausible edge
(streaming large blocklists) is covered by `URLSession.bytes(for:)` and `URLSessionDownloadTask`,
which additionally offer background and resume semantics.

## 07 · Security, Crypto & VPN

The category where being wrong is expensive. Two rules on top of the general ones: **key material
never leaves the Keychain in plaintext** (`SecretStore` is the only path), and **fail closed** — a
VPN that fails open is worse than no VPN, because the user believes they are protected.

**[WireGuardKit](07-security-crypto-vpn/wireguardkit.md)** · pinned `2fec12a6` · MIT · 🟢 Adopt (already in)
Already shipping, and the existing choices are right:
- **The commit pin is correct practice, not debt.** Known reviewable revision, reproducible
  builds, deliberate upgrades. *Do not replace it with a version range.*
- **The architecture is correct.** Traffic never passes through the browser process; the extension
  is separately signed, sandboxed, and entitled. A browser crash does not drop the tunnel; a
  browser compromise does not directly yield tunnel key material.
*Apple Silicon:* verify `libwg-go.a` is arm64 with `lipo -info` after any pin move — the most
likely breakage. The Go runtime inside the extension gives it an atypical thread/memory profile
worth measuring. ChaCha20-Poly1305 is not optimal on hardware with excellent AES acceleration, but
it is not negotiable in WireGuard and throughput is not the binding constraint.
*Pin-move checklist:* review the diff (handshake and timer logic especially) → rebuild and check
`lipo` → test establish/teardown/sleep-wake/network-transition → **verify DNS goes through the
tunnel** → update `AGENTS.md` and the manifest in the same commit.

**[swift-crypto](07-security-crypto-vpn/swift-crypto.md)** · 4.5.1 · Apache 2.0 · 🟢 Adopt
`DeviceKeyManager` handles WireGuard's Curve25519 keys — the most security-critical code in the
app. The types matter as much as the algorithms: `Curve25519.KeyAgreement.PrivateKey` makes it
hard to accidentally log, serialise, or transmit a private key.
**Prefer CryptoKit today** — same API, zero dependencies, and fewer dependencies is itself a
security property here. swift-crypto is the pre-approved escape hatch when a primitive is missing,
most plausibly for `EphemeralPeerNegotiator`'s post-quantum work.
*Risk:* **5.0.0 is in beta (beta.4).** Do not ship a beta crypto library in the module handling VPN
keys. Stay on 4.5.1.
> **Rule:** no hand-rolled cryptography in `VPNKit`, ever. A missing primitive means swift-crypto,
> not an implementation.

**[swift-certificates](07-security-crypto-vpn/swift-certificates.md)** · 1.19.4 · Apache 2.0 · 🔵 Trial
Two opportunities with very different risk profiles.
**Good:** pinning the Mullvad API. Today it trusts the system store, meaning hundreds of CAs can
issue for that host. For a privacy service, a mis-issued certificate on the relay-list endpoint is
a position from which to feed a user a manipulated relay set.
**Tempting and wrong:** certificate inspection UI. **WebKit already validates web content
certificates**, and its result governs whether a page loads. A second validation path that
disagrees is worse than none — it either shows the user something untrue or creates a distinction
with no security meaning. If such UI is built, source it from WebKit's `serverTrust` and use this
package for *display formatting only*.
*The gating risk:* **pinning bricks apps when certificates rotate.** Ship with backup pins and a
documented recovery path, or do not ship it.

**[mullvadvpn-app](07-security-crypto-vpn/mullvadvpn-app.md)** · 2026.3 / 2026.4-beta2 · GPL-3.0 · 🔴 Hold as dependency
Every hard problem in `VPNKit` — API endpoints, relay weighting and failover, key rotation
cadence, PQ ephemeral peer exchange, tunnel state machine, DNS and MTU handling — solved in Swift,
in production. **Invaluable as a document, prohibited as a dependency.**
*Useful intelligence from their releases:* 2026.4-beta2 fixed a split-tunnelling parse error on
**macOS 27** — worth knowing before Qwave's tunnel meets that OS.
> **Rule:** `VPNKit` contains no code derived from mullvadvpn-app. Behaviour is implemented from
> Mullvad's published API documentation and Apple's Network Extension documentation, covered by
> Qwave's own tests.

## 08 · UI: AppKit & SwiftUI

**The architecture constraint drives every verdict here.** Qwave is a thin AppKit shell with
SwiftUI control panes — AppKit for the tab bar, omnibox, find bar, window management and
`WKWebView` hosting (browsers live or die on first responder, focus, and drag-and-drop precision);
SwiftUI for the Settings and Library windows. **Packages assuming a SwiftUI-first app have less to
offer here than their popularity suggests.**

**[KeyboardShortcuts](08-ui-appkit-swiftui/keyboard-shortcuts.md)** · 3.0.1 · MIT · 🔵 Trial
The de facto standard for user-customisable shortcuts. The Qwave-specific actions are the
interesting ones — **new burner tab, switch container, toggle shields, toggle VPN, hibernate tab**
— because they have no Safari equivalent, so users have no muscle memory to preserve. The recorder
drops into a new Settings pane alongside the existing four.
*Constraint:* **global shortcuts require Accessibility or Input Monitoring permission.** Local
(app-scoped) shortcuts need none, and local is all a browser needs. A privacy-first browser asking
to monitor input is a contradiction users will notice.
*Also:* web pages capture keystrokes too — reserve a safe modifier space. Pin at ≥3.0.1 and test
release builds specifically; 3.0.1 fixed a release-build crash under the Swift 6.3 compiler.

**[Defaults](08-ui-appkit-swiftui/defaults.md)** · 9.0.9 · MIT · 🔵 Trial
Raises a question worth asking: **should `SettingsStore` be SQLite?** The SQLite choice is
defensible on sovereignty grounds — one file the user can inspect, back up, or delete, versus a
system-managed plist. **Keep it.**
Where Defaults fits is the **UI-state layer** that should not be in the sovereign data file at
all: window frames, sidebar widths, selected pane, tab bar options. The split is clean and easy to
explain: *your data is in one file you control; your window positions are not your data.*
*Note:* KeyboardShortcuts persists to `UserDefaults` itself, so bindings land on the UI-state side
by default — a decision to make, not discover. Also: `UserDefaults` plus a ~30-line typed-key
helper covers most of this with no dependency; weigh that seriously.

**[swift-navigation](08-ui-appkit-swiftui/swift-navigation.md)** · 2.11.0 · MIT · 🟡 Assess
**The idea is more valuable than the package.** Window management is spread across four files and
is imperative, so there is no single value describing "what is currently open" — which matters for
`SessionRestorer` (restoring *window* state is the natural extension of restoring tabs) and for
testing (you can assert over data, not over `showWindow(nil)`).
A `WindowDestination` enum plus an `@Observable` navigation model costs nothing and needs no
dependency. The package adds AppKit bindings on top — whose value depends on `AppKitNavigation`'s
maturity, which the release notes do not foreground and which needs direct verification.

**[SwiftUI Introspect](08-ui-appkit-swiftui/swiftui-introspect.md)** · 27.0.0-beta.2 · MIT · 🟡 Assess
Reaches the `NSView` behind a SwiftUI view when SwiftUI does not expose what you need. **Qwave has
a better escape hatch:** it is an AppKit app that occasionally uses SwiftUI — the inverse of
Introspect's target — so when AppKit control is needed, the answer is to write AppKit. Every
plausible case has a first-party alternative (`@FocusState`, `NSHostingView` in an `NSScrollView`,
`NSTableView`, the `NSWindow` from the controller that made it).
*Fundamental cost:* it depends on SwiftUI's **private view hierarchy**, so every OS release is a
potential break and you must enumerate supported versions.

## 09 · Build & Tooling

**What Qwave already has right:** `AGENTS.md` §1 — zero Xcode hand-edits, `project.yml` as the
single source of truth, `Qwave.xcodeproj` gitignored. That discipline is worth more than any tool
here: no project-file merge conflicts, reviewable build configuration, reproducible builds.

**[XcodeGen](09-build-tooling/xcodegen.md)** · 2.46.0 · MIT · 🟢 Adopt (already in)
For a browser shipping a **system extension**, having entitlements and signing configuration in
reviewable YAML is a security property, not just ergonomics — entitlement changes are exactly what
should never slip through unnoticed. **2.46.0's package traits support** is not abstract: it is
what the MLX trait-gating proposal needs, and it shows XcodeGen keeping pace with the platform.
*Worth adding to CI:* a generation check, and a guard rejecting any committed `.xcodeproj` —
turning the `AGENTS.md` rule from convention into enforcement.
*Risk:* single maintainer. Mitigated by the output being a standard `.xcodeproj` — worst case you
commit the generated project and move on.

**[swift-format](09-build-tooling/swift-format.md)** · 603.0.0 · Apache 2.0 · 🟢 Adopt
**The first quality gate to add.** First-party, ships with Xcode, nothing to install or cache in
CI. For a project with an explicit agent-facing `AGENTS.md`, consistent formatting matters more
than usual: when humans and agents both write code, whitespace churn hides the change that matters.
*Practice:* do the initial reformat as **one isolated commit** with no logic changes, then add its
hash to `.git-blame-ignore-revs`. Pin the CI toolchain — the 603.x scheme tracks swift-syntax, so
mismatched toolchains produce divergent lint results.

**[Periphery](09-build-tooling/periphery.md)** · 3.8.0 · MIT · 🔵 Trial
v0.1.0 shipped seven subsystems at once; code written that fast reliably contains scaffolding that
never got wired up. In a **security-sensitive** codebase unused code is a liability: reviewed less
carefully because it appears inert, reachable by reflection or a future change, and it inflates
the audit surface for anyone verifying the sovereignty claims.
*Configuration is load-bearing:* `retain_public: true` (QwaveKit is a library) and
`retain_objc_accessible: true` (AppKit/WebKit reach code through the Obj-C runtime). **Qwave's
`_WKFeature` `responds(to:)` reflection is exactly the pattern this tool struggles with** — tune
against it before trusting the output.
*Practice:* start report-only. A dead-code scanner that fails the build on day one gets disabled
on day two. Note that `retain_public` blunts the tool for most of `QwaveKit` — periodic manual
scans with it off are worth doing.

**[SwiftLint](09-build-tooling/swiftlint.md)** · 0.65.0 · MIT · 🟡 Assess
The style half is redundant after swift-format; the **correctness half is valuable**. Three rules
earn their place: `force_unwrapping` (a `!` in `VPNKit` or `Persistence` is a crash that loses the
user's tabs), `discarded_notification_center_observer`, and above all **`weak_delegate`** —
`NavigationCoordinator`, `DownloadManager`, and `FindInPageController` are WebKit delegates, and a
retain cycle there **leaks `WKWebView` instances**, defeating hibernation silently while the tab
reports as hibernated.
*Custom rules can encode Qwave's own invariants* — banning `print(` in favour of
`QwaveSupport.Log`, banning direct `SecItem*` calls in favour of `SecretStore`. Those modules
exist so nothing else does that work, and nothing currently guards the bypass.
*Required:* disable the rules that overlap swift-format, and exclude `Packages/WireGuardKit` —
linting a pinned upstream creates pressure to modify code that must stay identical.

**[Tuist](09-build-tooling/tuist.md)** · 1.256.4 · MIT · 🟡 Assess
Its differentiator is **build caching**, whose value scales with module count. Qwave is **6
modules and a 4 KB `project.yml`** — YAML is the right tool at that size, and clean builds are
already fast. Migration means rewriting `AGENTS.md`, CI, and `docs/SIGNING.md` to buy caching for
a project that does not need it. **Revisit past ~15–20 modules.**

**[swift-build](09-build-tooling/swift-build.md)** · Swift 6.3.1 · Apache 2.0 · 🔴 Hold
The open-sourced engine under SwiftPM and Xcode. Nothing to adopt; it arrives with the toolchain.
Real benefit: `swift test` and `xcodebuild` converge on one engine, and Qwave uses both.
**The actionable item is elsewhere: pin the Xcode version in CI.** Tracking `latest` lets a new
release change build behaviour, formatter output, and language-mode defaults without a commit.

## 10 · Testing & Quality

**Qwave's coverage is better than most v0.1.0 releases** — all six modules have tests, and
`VPNKitTests` has a `MockURLProtocol` plus a `relays.json` fixture, so the network layer is tested
without network access. That is deliberate test design, not coverage-chasing.

**[swift-testing](10-testing-quality/swift-testing.md)** · Swift 6.3.2 · Apache 2.0 · 🟢 Adopt
Ships with the toolchain; coexists with XCTest in one target, and `swift test` merges results — so
migration is incremental with no flag day. Three properties map onto Qwave directly:
1. **Parameterised tests.** `ShieldsPolicyTests`, `OmniboxParserTests`, and
   `HTTPSFirstUpgraderTests` are input→expectation tables — the shape XCTest expresses worst. Under
   `@Test(arguments:)` every case reports individually and a failure *names the input*.
2. **Async without ceremony.** `XCTestExpectation` timeouts are a common source of flaky tests — a
   timeout too short on a loaded runner fails a correct test.
3. **Runtime concurrency diagnostics**, which pair with the Swift 6.2 migration: they are how you
   gain confidence the migration introduced no races.
*Main hazard:* **parallel-by-default surfaces shared state.** `PersistenceTests` targets SQLite —
give each test its own database file, or use `@Suite(.serialized)`. Migrate it last.
*XCTest keeps:* XCUITest, `XCTMetric` performance measurement, Objective-C tests.

**[swift-snapshot-testing](10-testing-quality/swift-snapshot-testing.md)** · 1.19.4 · MIT · 🔵 Trial
Three fits, all structured-artifact comparisons: compiled `WKContentRuleList` JSON, **WireGuard
tunnel configurations**, and decoded/filtered relay selection. The tunnel case is the strongest —
a change that silently alters `AllowedIPs` or DNS is a **leak**, and a snapshot makes it impossible
to merge unnoticed. The rule-list case becomes important if SafariConverterLib lands: a snapshot
diff is how you review an upstream rule update that would otherwise be an unreviewable blob.
*The failure mode is blind re-recording.* For security-relevant output that defeats the purpose
entirely — a reviewer waving through a `TunnelSessionConfig` snapshot change is waving through a
possible leak. Avoid image snapshots; they vary with OS version, scale, and fonts.

**The gap worth naming:** Qwave has **no integration test against a real `WKWebView`**. Every test
is a unit test against a mock or fixture. Defensible for v0.1.0 — WebKit tests are slow and flaky
in CI — but the highest-value untested paths run straight through it. Does `TabHibernator`
actually reclaim memory? Does `ShieldsDirector` actually block a request? Does
`HTTPSFirstUpgrader` actually upgrade a navigation? A small suite serving pages from local file
URLs would cover the README claims that nothing currently verifies.

## 11 · Performance & Energy

See [finding 5](#5--the-energy-claim-is-asserted-not-measured--and-the-obvious-tool-cannot-measure-it).

**What is worth measuring**, in rough priority: resident memory before/after hibernation
(`TabHibernator` — the core product claim); wake latency (the cost the user pays for the memory);
`WKContentRuleList` compile time (grows with rule count); history query latency at scale
(degrades over months); session restore time (felt at launch); omnibox parse time (every keystroke).

**The measurement stack:**

| Tool | Use |
|------|-----|
| `os_signpost` | Instrument hibernate/wake in `QwaveSupport/Log.swift`; visible in Instruments |
| Instruments — Energy Log | Real battery impact — the only ground truth for energy claims |
| `XCTMetric` (`XCTMemoryMetric`, `XCTClockMetric`) | Whole-system memory in existing XCTest suites |
| [package-benchmark](11-performance-energy/package-benchmark.md) | In-process regression thresholds in CI |
| `MetricKit` | Field data — reports to Apple, not a third party, and OS-level opt-in. Less objectionable than typical telemetry, but still a product decision to make explicitly |

**[package-benchmark](11-performance-energy/package-benchmark.md)** · 1.36.2 · Apache 2.0 · 🔵 Trial
Measures far more than wall-clock: CPU time, allocations, retain/release traffic, peak resident
memory, syscalls, context switches — in percentiles, with **committed baselines and CI regression
detection**. Strong candidates: `OmniboxParser` (every keystroke), `HistoryStore` at scale,
`RuleListCompiler`, `SessionRestorer`, `RelaySelector`.
*Apple Silicon:* `mallocCountTotal` is the right metric — allocation traffic often matters more
than instruction count, and it is deterministic, unlike wall-clock on shared runners. Baselines
are only comparable on consistent hardware; pin the runner class.
*Start with `OmniboxParser`* — pure in-process, existing tests, and the natural place to prove the
[WebURL](01-webkit-browser-engine/weburl.md) migration in measured rather than asserted terms.

## 12 · Distribution & Updates

See [finding 1](#1--code-signing-is-the-highest-leverage-work-available-and-it-is-not-a-code-change).

**[Sparkle](12-distribution-updates/sparkle.md)** · 2.9.5 · MIT-style · 🟢 Adopt (after signing)
The macOS update standard. Sparkle 2 supports sandboxing, custom UI, **external bundle updates**
(directly relevant — Qwave ships `PacketTunnel.systemextension` alongside the app), and a
modernised installer.
**EdDSA-signed appcasts are the security model:** a compromised download host cannot serve a
malicious update without the private key — an answer that is verifiable independently of GitHub,
TLS, or the CDN. That fits a product whose users *should* ask "how do I know this update is really
from you?"
*The 2.9.5 fix is a good signal:* hardening delta patching against a symlink at the destination
path is exactly the vulnerability class an update framework must get right.
*Risks:* **the EdDSA private key is critical infrastructure** — whoever holds it ships code to
every user; CI secret only, with a documented rotation plan before the first release. Update checks
are network traffic, so make the setting visible and honour it. Updating an app that hosts an
approved system extension can require re-approval — test on a clean machine. **Signing must come
first**: Sparkle installing an unsigned update is an unauthenticated code-execution path.
*App Store distribution is a poor alternative here* — sandbox restrictions, the system-extension
approval flow, and `FeatureFlags`' Safari SPI usage all sit awkwardly with review, and the
sovereignty positioning argues for direct distribution regardless.

---

# Part V · What Was Rejected, and Why

The Hold and lower-Assess entries in one place, so the questions close rather than recur.

| Question | Answer | One line |
|----------|--------|----------|
| "Should Qwave use a real HTTP client?" | 🔴 [SwiftNIO](06-networking/swift-nio.md), [AsyncHTTPClient](06-networking/async-http-client.md) | `URLSession` follows the tunnel; a custom stack is a leak surface |
| "We're on Apple Silicon — should we use Metal?" | 🟡 [Metal 4](03-gpu-metal-compute/metal-4.md), [Alloy](03-gpu-metal-compute/alloy.md) · 🔴 [MetalPetal](03-gpu-metal-compute/metalpetal.md) | WebKit owns the GPU; a second consumer starves the renderer |
| "Should Qwave do voice search?" | 🔴 [WhisperKit](02-on-device-ai/whisperkit.md) | System dictation already works, at zero cost and without a microphone entitlement |
| "Shields should be more like Brave's" | 🟡 [adblock-rust](01-webkit-browser-engine/adblock-rust.md) | Right instinct, wrong package — SafariConverterLib + a bigger rule set |
| "Can we depend on Mullvad's client?" | 🔴 [mullvadvpn-app](07-security-crypto-vpn/mullvadvpn-app.md) | GPL-3.0 in an MIT app. Read it; do not link or transliterate it |
| "Should we migrate to Tuist?" | 🟡 [Tuist](09-build-tooling/tuist.md) | Caching scales with module count; Qwave has 6 |
| "swift-build is open source now — use it?" | 🔴 [swift-build](09-build-tooling/swift-build.md) | It is the engine under the tools already in use. Pin Xcode in CI instead |
| "Do we need atomics?" | 🔴 [swift-atomics](04-concurrency-runtime/swift-atomics.md) | Stdlib `Synchronization` supersedes it — and Qwave should need neither |
| "SwiftData alternative for Persistence?" | 🟡 [SQLiteData](05-persistence-data/sqlite-data.md) | Flagship feature is CloudKit sync, which the product must refuse |
| "Reach into SwiftUI internals for the Settings panes?" | 🟡 [SwiftUI Introspect](08-ui-appkit-swiftui/swiftui-introspect.md) | Qwave owns the AppKit layer already — write the `NSView` |

---

# Part VI · Open Questions

Things this research could not settle, flagged rather than glossed. Each needs verification before
the corresponding recommendation is acted on.

| # | Question | Blocks | How to resolve |
|---|----------|--------|----------------|
| 1 | **Licences were stated from knowledge, not fetched.** Most are low-risk (Apache 2.0 / MIT), but **SafariConverterLib's copyleft terms are a hard gate** and filter lists carry separate terms | Phase 3.1 | Read the actual `LICENSE` files; get a considered interpretation before writing code |
| 2 | **Does `WebPage.Configuration` expose the `_WKFeature` SPI hook** that `FeatureFlags` reflects over? | Whether WebKit-for-SwiftUI can ever *replace* rather than parallel the current path | Cheap spike on a macOS 26 machine — do this first |
| 3 | **How mature is `AppKitNavigation`** relative to the SwiftUI and UIKit modules? Release notes do not foreground it | swift-navigation verdict | Read the module's source and test coverage directly |
| 4 | **Is Alloy current with Metal 4?** It predates the redesign | Alloy verdict (already 🟡) | Check for `MTLTensor` / `MTL4*` support; low priority |
| 5 | **Release *years* are not confirmable** from GitHub's release pages, which render month/day for recent entries | Nothing — versions are correct | Versions are recorded with a "verified 2026-08-12" stamp rather than asserted release years |
| 6 | **adblock-rust has no tagged GitHub releases**; it is versioned on crates.io as `adblock` | Nothing — verdict is 🟡 regardless | Check crates.io if it is ever revisited |
| 7 | **Do MLX's GPU cache limits actually bound its footprint** enough to coexist with WebKit content processes under pressure? | MLX advancing past Trial | Measure with `MLX.GPU.set(cacheLimit:)` under a realistic tab load |
| 8 | ~~Does `EnergyGovernor` expose a discretionary-work signal?~~ **Resolved.** It is a pure enum: `tier(for: EnergyConditions)` → `policy(for:baseHibernationTimeout:)`. Gate discretionary work on `tier == .normal`. `EnergyConditions` samples thermal state, low-power mode, and occlusion — **not memory**, which the MLX proposal would need added | — | Read directly during this research; notes corrected |

Everything else in this document was verified against upstream sources on **2026-08-12**. Versions
move fast in this ecosystem — **re-verify before pinning anything.**

---

# Sources

**Apple** — [Meet WebKit for SwiftUI (WWDC25 · 231)](https://developer.apple.com/videos/play/wwdc2025/231/)
· [Discover Metal 4 (WWDC25 · 205)](https://developer.apple.com/videos/play/wwdc2025/205/)
· [Optimize custom ML operations with Metal tensors (WWDC26 · 330)](https://developer.apple.com/videos/play/wwdc2026/330/)
· [What's new in Foundation Models (WWDC26 · 241)](https://developer.apple.com/videos/play/wwdc2026/241/)
· [Bring an LLM provider to Foundation Models (WWDC26 · 339)](https://developer.apple.com/videos/play/wwdc2026/339/)
· [Exploring LLMs with MLX and the M5 GPU Neural Accelerators](https://machinelearning.apple.com/research/exploring-llms-mlx-m5)
· [Apple debuts M5 Pro and M5 Max](https://www.apple.com/newsroom/2026/03/apple-debuts-m5-pro-and-m5-max-to-supercharge-the-most-demanding-pro-workflows/)

**Swift** — [Swift 6.2 Released](https://www.swift.org/blog/swift-6.2-released/)
· [Approachable Concurrency in Swift 6.2](https://www.avanderlee.com/concurrency/approachable-concurrency-in-swift-6-2-a-clear-guide/)
· [Approachable Concurrency in Swift Packages](https://useyourloaf.com/blog/approachable-concurrency-in-swift-packages/)
· [Swift Package Index joins Apple](https://swiftpackageindex.com/blog/swift-package-index-joins-apple)

**Platform** — [Apple releases first iOS 27 / macOS 27 betas](https://www.macrumors.com/2026/06/08/apple-releases-ios-27-beta-1/)
· [Xcode 27: everything developers need to know](https://dev.to/arshtechpro/xcode-27-everything-developers-need-to-know-6lh)
· [macOS 27 Golden Gate guide](https://www.macworld.com/article/3139330/macos-27-mac-features-siri-apple-intelligence-release-date-compatibility.html)

**Packages** — versions verified 2026-08-12 against each project's GitHub releases page. Per-package
repository links are in the [verdict matrix](#verdict-matrix--all-40-packages) and in the
individual notes under [`research/`](README.md).

---

*Qwave · best-of-three macOS browser · 8b.is · digest verified 2026-08-12*
