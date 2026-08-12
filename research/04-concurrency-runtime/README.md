# 04 · Concurrency & Runtime

| Package | Version | Verdict | Qwave module |
|---------|---------|---------|--------------|
| [swift-collections](swift-collections.md) | 1.6.0 | 🟢 Adopt | `BrowserCore/TabManager`, `Persistence` |
| [swift-async-algorithms](swift-async-algorithms.md) | 1.1.5 | 🔵 Trial | `Shields/BlocklistUpdater`, `VPNKit` |
| [swift-subprocess](swift-subprocess.md) | 1.0.0 | 🟡 Assess | Build tooling only |
| [swift-atomics](swift-atomics.md) | — | 🔴 Hold | Superseded by the stdlib |

---

## The bigger item is not a package

Qwave is pinned to **Swift 5.10 with the `targeted` concurrency stance** (`AGENTS.md` §3), while
the toolchain has reached **Swift 6.4**. The single highest-value change in this category is
migrating to the **Swift 6.2 "Approachable Concurrency"** model — see
[PLATFORM-BASELINE.md](../PLATFORM-BASELINE.md) for what that buys.

The short version, in Qwave's terms:

- **Main-actor-by-default** for the AppKit shell removes annotation noise from
  `Sources/QwaveApp/*`, which is main-actor by nature.
- **`nonisolated(nonsending)` by default** removes actor hops and false-positive warnings on the
  `TabManager` ↔ `TabHibernator` ↔ `EnergyGovernor` path, where tab state crosses isolation
  boundaries on every hibernate/wake cycle.
- **Runtime concurrency diagnostics under test** catch races that static analysis misses —
  and `BrowserCoreTests` already drives exactly those concurrent paths.

Do it **module by module** using upcoming-feature flags in `Package.swift`, not as one flip.
`QwaveSupport` and `Persistence` are the natural first two: small, leaf-ward, well tested.

## Why the package list is short

The Swift standard library absorbed most of this category. `Mutex` and `Atomic` live in the
`Synchronization` module; structured concurrency, `AsyncSequence`, and actors are language
features. What remains worth depending on are the data structures the stdlib does not ship
(`swift-collections`) and the async operators it does not provide (`swift-async-algorithms`).

That absorption is why [swift-atomics](swift-atomics.md) is a **Hold** — it is a package whose
job the platform now does, and depending on it in new code is a mistake worth writing down.
