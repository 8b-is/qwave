# MLX Swift (`ml-explore/mlx-swift`)

| | |
|---|---|
| **Repo** | https://github.com/ml-explore/mlx-swift |
| **Version** | **0.31.6** (published 2026-07-02) |
| **Companion** | MLX core (C++/Python) at **0.32.0** (Jul 2026) |
| **License** | MIT |
| **Platforms** | macOS 14+, iOS 16+ — **Apple Silicon only** |
| **Apple Silicon** | This is the entire point: unified memory, Metal GPU, M5 Neural Accelerators |
| **Verified** | 2026-08-12 |

---

## What it is

Apple's array framework for machine learning on Apple Silicon, with a native Swift API. MLX is
built around **unified memory**: arrays live in memory shared by CPU and GPU, so operations run
on either device with no explicit transfer. Lazy evaluation means graphs are only materialised
when a result is actually needed.

MLX Swift is the API for embedding this in a shipping app — running and fine-tuning models
on-device — as opposed to the Python API used for research. The release cadence is roughly
every few weeks, tracking the C++ core closely.

Two developments in 2026 changed its position:

1. **M5 Neural Accelerators.** MLX uses the per-GPU-core Neural Accelerators on M5, requiring
   **macOS 26.2+**. This is where the 3.3×–4.06× time-to-first-token gains over M4 come from.
2. **WWDC26 provider protocol.** Any MLX model can now serve as a Swift-native backend behind
   Apple's `FoundationModels` API, alongside an OpenAI-compatible server and distributed
   inference.

Point 2 is strategically important for Qwave: it means the *choice* between MLX and Foundation
Models is no longer architectural. Write against `LanguageModelSession` and the backend becomes
a swap.

## Why it matters for Qwave

Three features are plausible, in descending order of value:

1. **Page summarisation.** Summarise the current tab without the page content leaving the
   machine. This is the flagship sovereignty demo — every cloud browser assistant is a data
   exfiltration channel by construction, and this one structurally cannot be.
2. **Local omnibox reranking.** `Persistence/HistoryStore.swift` holds the user's history.
   Ranking it locally beats shipping prefixes to a search provider.
3. **Heuristic shield assist.** Score unknown hosts against learned patterns to supplement the
   static rule list. Interesting, and the most speculative of the three.

## Apple Silicon notes

This package exists because of Apple Silicon, so the architectural fit is total:

- **Unified memory** removes the host↔device copy that dominates small-batch inference on
  discrete GPUs. On an M5 Max with 128 GB at 614 GB/s, models that need a workstation elsewhere
  run in a laptop's memory space.
- **Neural Accelerators** (macOS 26.2+, M5+) accelerate the matmul-heavy prefill phase, which is
  what time-to-first-token measures — the latency the user actually perceives.
- **Memory is shared with the browser.** This is the flip side and the real engineering
  constraint: MLX allocations compete directly with WebKit content processes for the same pool.
  A 7B model at 4-bit is ~4 GB resident. `TabHibernator` exists to *reclaim* memory; an
  inference module must not quietly consume everything it frees.

## Adoption sketch

Keep it out of the default build. A separate SwiftPM **trait** or an entirely separate optional
module is the right shape:

```swift
// Package.swift — behind a trait so the default build is untouched
traits: [ .trait(name: "LocalAI") ],
dependencies: [
    .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.31.6", condition: .when(traits: ["LocalAI"]))
]
```

XcodeGen 2.46 supports package traits for remote and local references, so this composes with
Qwave's generation pipeline.

```swift
// Gate every inference call on the existing energy policy
@available(macOS 26.2, *)
func summarise(_ text: String) async throws -> String {
    guard EnergyGovernor.shared.allowsDiscretionaryWork else { throw AIError.deferred }
    // ... MLX inference
}
```

`EnergyGovernor` is already the arbiter for hibernation decisions. Reusing it here keeps one
policy surface instead of two.

## Risks

- **Model distribution.** Multi-gigabyte weights cannot ship in the app bundle. That means a
  download flow, integrity verification, storage management, and update handling — a real
  subsystem, larger than the inference code itself.
- **Memory contention with WebKit.** The direct conflict with `TabHibernator`'s purpose.
  Non-negotiable: no inference under memory pressure.
- **Energy.** Sustained GPU inference is the most power-hungry thing this app could do, in a
  browser whose pitch is battery life.
- **Pre-1.0 with a fast cadence.** Releases every few weeks and a 0.x version. Pin exactly.
- **macOS 26.2 floor** for the M5 acceleration path — four minor versions past Qwave's target.

## Verdict

🔵 **Trial — optional module, behind a trait, gated on `EnergyGovernor`.**

The technology is real, the hardware fit is excellent, and the sovereignty story is genuinely
differentiating rather than decorative. But the model-distribution and memory-contention
problems are bigger than the inference code, and the browser must remain complete without it.

**Sequence:** ship a summarisation feature on [Foundation Models](foundation-models.md) first —
no download, no storage, no model management. If and only if Apple's ~3B model proves
insufficient for the task, swap the backend to MLX behind the same `LanguageModelSession` API
that WWDC26 opened up. That ordering gets the feature in front of users at a fraction of the
cost and keeps the expensive path available.

---

**References:**
[MLX Swift](https://github.com/ml-explore/mlx-swift) ·
[Exploring LLMs with MLX and the M5 GPU Neural Accelerators](https://machinelearning.apple.com/research/exploring-llms-mlx-m5)
