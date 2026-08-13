---
title: "The measured cost of a Swift module boundary"
status: draft
date: 2026-08-13
tags: [swift, performance, module, compilation, macos]
measured_on: "Apple M1 Max (8 P-cores / 2 E-cores), 64 GB unified memory, macOS 26.4, Xcode 16.4 (Swift 6.3.1). Release build, package-benchmark mallocCountTotal + retainCount + releaseCount + retainReleaseDelta."
corrections: "v3 — Clean before/after comparison with ARC metrics. The earlier 'null result' was based on mallocCountTotal alone, which misses ARC traffic. This version measures with the correct instruments."
---

## The question

Swift does not specialise generics or inline across module boundaries by default. Qwave has a 6-way SPM module split in `QwaveKit`. Does the module boundary cost measurable performance?

## Method

1. Measured all 5 benchmarks WITH `@inlinable` / `@usableFromInline` annotations on hot functions (`OmniboxParser.parse`, `OmniboxParser.url(from:)`, `OmniboxParser.isIPv4(_:)`, `OmniboxSuggester.suggestions`, `OmniboxSuggester.matchScore`)
2. Removed ONLY those annotations (no other changes)
3. Re-measured the same benchmarks
4. Compared mallocCountTotal, retainCount, releaseCount, and retainReleaseDelta

## Results

| Benchmark | Metric | WITH @inlinable | WITHOUT | Δ |
|---|---|---|---|---|
| OmniboxParser.parse | Malloc | 27 | 27 | 0% |
| | Retains | 20 | 20 | 0% |
| | Releases | 53 | 53 | 0% |
| OmniboxSuggester (500 entries) | Malloc | 1,011 | 1,011 | 0% |
| | Retains | 6,536 | 6,536 | 0% |
| | Releases | 7,554 | 7,554 | 0% |
| HistoryStore (50k rows) | Malloc | 441 | 441 | 0% |
| | Retains | 605 | 605 | 0% |
| | Releases | 1,032 | 1,032 | 0% |
| SessionRestorer (40 tabs) | Malloc | 65 | 65 | 0% |
| | Retains | 557 | 557 | 0% |
| | Releases | 913 | 913 | 0% |
| UBORuleListCompiler (1k rules) | Malloc | 50K | 50K | 0% |
| | Retains | 82K | 82K | 0% |
| | Releases | 116K | 116K | 0% |

**Every metric showed 0% change.** The annotations have no measurable effect on allocation count, ARC traffic, or retain/release patterns.

## What else was checked

| Technique | Status | Finding |
|---|---|---|
| WMO (whole-module opt) | ✅ Enabled by default in SPM Release | — |
| `final` on classes | ✅ All 34 public classes already `final` | No change needed |
| `any Protocol` existentials | ✅ None on hot paths | No change needed |
| `-cross-module-optimization` | ❌ Not enabled | Requires build-system change |

## Conclusion

**`@inlinable` / `@usableFromInline` on these functions has zero measurable effect on the metrics that matter.** All 5 benchmarks show identical numbers across allocation counts, retain counts, release counts, and retain-release deltas.

The annotations are not harmful, but they bake implementation detail into the module's ABI surface — a real maintenance cost for future changes. A change to any `@inlinable` function requires recompiling all consumers, even if the change is internal.

**Recommendation: remove the `@inlinable` / `@usableFromInline` annotations.** The measured evidence does not support keeping them. The ABI commitment is a real cost with no measured benefit.

**Not checked:** `-cross-module-optimization` / `-enable-cmo` requires build-system changes outside the SPM package scope. May be worth revisiting with a dedicated build configuration.

**Not done:** Module collapse. The 6-way split serves build times, testability, and the `QwaveTunnelKit` boundary that keeps the tunnel from linking the browser.