---
title: "The measured cost of a Swift module boundary"
status: draft
date: 2026-08-13
tags: [swift, performance, module, compilation, macos]
measured_on: "Apple M1 Max (8 P-cores / 2 E-cores), 64 GB unified memory, macOS 26.4, Xcode 16.4 (Swift 6.3.1). Release build, package-benchmark mallocCountTotal + retainCount + releaseCount + retainReleaseDelta."
---

# The measured cost of a Swift module boundary

*Long-form engineering post. Illustrations generated via the entheai engine
(`vaked` provider, deepseek-v3.2) and hand-polished for correctness.*

Swift does not specialise generics or inline functions across module
boundaries by default. Qwave's engine is split six ways inside the
`QwaveKit` package — `BrowserCore`, `Shields`, `Persistence`, `URLIdentity`,
`VPNKit`, `FeatureFlags` — and the hot paths (omnibox parse, suggestion
ranking) live in one module while the benchmarks that measure them live in
another. The natural question, and one that shows up in every Swift code
review eventually: *does that boundary cost us anything measurable, and is
[`@inlinable`](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/attributes/#inlinable) the fix?*

The answer, after a proper experiment: **no, and no.** The boundary is free
on the metrics that matter; `@inlinable` changes none of them. The honest
story is a null result that had a real consequence: we deleted the
annotations.

## The method that makes the null result believable

A null result is only worth anything if the instrument could have caught a
non-null one. The first version of this experiment measured
`mallocCountTotal` alone and concluded "no effect" — and a reviewer was right
to distrust it, because `@inlinable` doesn't move allocation counts; it moves
*dispatch and specialization*, which show up as ARC traffic, not `malloc`
calls. So the method was tightened
([commit `28c3d9e`](https://github.com/8b-is/qwave/commit/28c3d9eab0a7b4316bf0a96daad0bc29e346eff2),
[`dac7187`](https://github.com/8b-is/qwave/commit/dac7187919701d36b5fff2166bab89828f713bdd)):

1. Measure all five benchmarks **with** [`@inlinable`](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/attributes/#inlinable) / [`@usableFromInline`](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/attributes/#usableFromInline) on
   the hot functions (`OmniboxParser.parse`, `OmniboxParser.url(from:)`,
   `OmniboxParser.isIPv4(_:)`, `OmniboxSuggester.suggestions`,
   `OmniboxSuggester.matchScore`).
2. Remove **only** those annotations — no other change.
3. Re-measure the same benchmarks.
4. Compare four metrics: `mallocCountTotal`, `retainCount`, `releaseCount`,
   and `retainReleaseDelta`.

The ARC metrics are the part that matters. `retainCount`/`releaseCount` are
what an inlining decision would actually perturb — inlining changes where the
retain/release pairs land, and if the boundary cost were real, the inlined
build would show fewer or different retain/release events. The metrics are
now part of the CI gate itself
([`QwaveKitBenchmarks.swift L24-L35`](https://github.com/8b-is/qwave/blob/088f0680efcefca542d427af20184574e693085c/Benchmarks/Benchmarks/QwaveKitBenchmarks/QwaveKitBenchmarks.swift#L24-L35)),
with a tighter 5% tolerance than `mallocCountTotal`'s 25% — ARC counts are
more sensitive to change, so they get the tighter leash.

## The result: zero, exactly

| Benchmark | Metric | WITH | WITHOUT | Δ |
|---|---|---|---|---|
| OmniboxParser.parse | Malloc / Retains / Releases | 27 / 20 / 53 | 27 / 20 / 53 | **0%** |
| OmniboxSuggester (500 entries) | Malloc / Retains / Releases | 1,011 / 6,536 / 7,554 | 1,011 / 6,536 / 7,554 | **0%** |
| HistoryStore (50k rows) | Malloc / Retains / Releases | 441 / 605 / 1,032 | 441 / 605 / 1,032 | **0%** |
| SessionRestorer (40 tabs) | Malloc / Retains / Releases | 65 / 557 / 913 | 65 / 557 / 913 | **0%** |
| UBORuleListCompiler (1k rules) | Malloc / Retains / Releases | 50K / 82K / 116K | 50K / 82K / 116K | **0%** |

![Bar chart: WITH vs WITHOUT @inlinable — identical across malloc, retain, release; Δ = 0%](assets/inlinable-null-result.svg)

Every metric, on every benchmark, identical to the last retain. Not "within
noise" — *identical*. That is the signature of a structural non-effect, not a
measurement that happened to miss.

Why is the boundary free? Because Swift's calling convention and the
optimizer already handle the simple case: the functions in question are
non-generic, monomorphic, and cheap to call. The *dispatch* cost of calling
`OmniboxSuggester.suggestions` across a module boundary is a single symbol
indirection — nanoseconds, zero allocations, zero extra retain/release
traffic. `@inlinable` would only matter if the function were generic,
specializable, or if a whole-function optimization could then fold into the
caller. None of that applies here.

![Diagram: what @inlinable actually does at a module boundary — and why the measured cost is 0%](assets/module-boundary-inlining.svg)

## The cost that *is* real: the ABI commitment

Here's the part that makes this not merely an academic null result.
`@inlinable` is not free even when its runtime effect is zero, because it
bakes the function *body* into the module's ABI surface:

* **A change to any `@inlinable` body forces a recompile of every consumer.**
  The body is copied into each importing module, so an internal edit — even a
  refactor that changes nothing observable — invalidates every downstream
  build. You have traded a hypothetical nanosecond for a guaranteed rebuild
  cascade.
* **`@usableFromInline` widens access.** To make a `private` helper
  inlinable, you must promote it to `@usableFromInline` (effectively internal,
  name-visible, ABI-frozen). In Qwave's case that meant `matchScore`,
  `url(from:)`, and `isIPv4` could no longer be `private` — a real
  information-hiding cost, paid for a benefit that measured as zero.

So the recommendation, backed by the measurement, was to **remove the
annotations** — and that's exactly what happened
([commit `23f88e6`](https://github.com/8b-is/qwave/commit/23f88e6519cda31063f802829b00a3f46f172524),
"structural: remove @inlinable, wire warmProcessCount"). The functions
reverted from `@usableFromInline` to plain `private`
([`OmniboxParser.swift L88, L100`](https://github.com/8b-is/qwave/blob/088f0680efcefca542d427af20184574e693085c/Packages/QwaveKit/Sources/BrowserCore/OmniboxParser.swift#L88),
[`OmniboxSuggester.swift L64`](https://github.com/8b-is/qwave/blob/088f0680efcefca542d427af20184574e693085c/Packages/QwaveKit/Sources/BrowserCore/OmniboxSuggester.swift#L64)),
and the public entry points lost their `@inlinable`
([`OmniboxParser.parse L12`](https://github.com/8b-is/qwave/blob/088f0680efcefca542d427af20184574e693085c/Packages/QwaveKit/Sources/BrowserCore/OmniboxParser.swift#L12),
[`OmniboxSuggester.suggestions L27`](https://github.com/8b-is/qwave/blob/088f0680efcefca542d427af20184574e693085c/Packages/QwaveKit/Sources/BrowserCore/OmniboxSuggester.swift#L27)).
The null result bought back the `private` keyword. That is a null result
*doing work*.

## What was checked but not measured

* **WMO ([whole-module optimization](https://github.com/swiftlang/swift/blob/main/docs/Driver.md))** — already the default for SPM Release
  builds, so nothing to enable.
* **[`final`](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/inheritance/#Preventing-Overrides) classes** — all 34 public classes were already `final`; no devirtualization left on the table.
* **[`any` Protocol](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/opaquetypes/) existentials** — none on the hot paths.
* **[`-cross-module-optimization`](https://github.com/swiftlang/swift/blob/main/docs/Driver.md) / `-enable-cmo`** — *not* enabled. This is
  the one genuine lever left untested, and it's a build-system change outside
  the SPM package's scope. If someone later cares about cross-module
  specialization, this is the flag to reach for — not `@inlinable` spray.
* **Module collapse** — the 6-way split serves build times, testability, and
  the `QwaveTunnelKit` boundary that keeps the WireGuard tunnel from linking
  the browser. Collapsing it to chase a 0% metric would be the wrong trade,
  so it wasn't done.

## Key takeaways

1. **A null result is only credible if the instrument could have caught the
   effect.** The first pass (malloc-only) was right but for the wrong reason;
   adding ARC metrics is what made "0%" mean something.
2. **[`@inlinable`](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/attributes/#inlinable) is not a performance flag; it is an ABI commitment.** On
   simple, monomorphic, cheap functions it measures as zero and costs you a
   rebuild cascade plus a widened access level.
3. **Measure, then delete.** The annotations were removed because the
   evidence said to, and the code got *simpler* — [`@usableFromInline`](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/attributes/#usableFromInline)
   functions became `private` again.
4. **Reach for [`-cross-module-optimization`](https://github.com/swiftlang/swift/blob/main/docs/Driver.md) before [`@inlinable`](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/attributes/#inlinable).** One is a
   whole-program compiler flag; the other is a permanent promise you make to
   every future consumer.

*Sister posts in this series:
[zero-allocation text on the keystroke path](zero-allocation-text-on-the-keystroke-path.md) ·
[what 59,657 blocking rules cost](what-59657-blocking-rules-cost.md) ·
[why we count allocations not wall clock](why-we-benchmark-allocations-not-wall-clock.md) ·
[measuring memory a browser doesn't own](measuring-memory-a-browser-doesnt-own.md).*
