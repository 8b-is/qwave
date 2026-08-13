---
title: "Why we benchmark allocations, not wall-clock"
status: draft
date: 2026-08-13
tags: [swift, performance, benchmarking, ci, macos]
measured_on: "N/A — methodology post, not a measurement."
---

# Why we benchmark allocations, not wall-clock

*Long-form engineering post. Illustrations generated via the entheai engine
(`vaked` provider, deepseek-v3.2) and hand-polished for correctness.*

Every benchmark harness wants to measure one thing: is this code faster than
it was? And almost every team reaches for the same instrument to answer it —
a stopwatch. This post is the argument that, for a Swift app built on shared
CI hardware, the stopwatch is the *wrong* instrument, and the right one is
much less glamorous: **counting `malloc` calls.**

It is a methodology post, which means it is an essay about which numbers to
trust. The payoff is concrete: a benchmark suite that has never produced a
false positive, on runners that vary by ±30% in wall-clock time.

## The problem: your stopwatch is lying on shared runners

We run Qwave's benchmarks on Blacksmith `macos-15` shared runners (6 vCPU).
A shared runner is a box you don't own, sharing a host with other people's
jobs, on thermal states you don't control. Wall-clock time on it varies by
**±30% or more** for the *same binary*, because the CPU is contended, the
cache is cold, or the scheduler is doing something else entirely.

![Two panels: wall-clock varies ±30% across runs, while mallocCountTotal is identical across runs](assets/wallclock-vs-mallocs.svg)

A ±30% instrument is worse than useless for catching a 2× regression — it
*can't*. A genuine 2× slowdown hides inside the noise, and a lucky run of
regressed code reads as an improvement. Wall-clock on shared runners doesn't
measure your code; it measures the host. The first decision was therefore
not "how do we benchmark" but "what is actually *invariant* about our code,
independent of the host."

## The invariant: allocation counts

A given code path allocates the same things every time it runs. It doesn't
matter whether the CPU is contended, whether the cache is warm, whether ASLR
scrambled the addresses, or whether the fan is screaming — `OmniboxSuggester`
scoring 500 entries performs the same number of `malloc`s on a cold shared
runner as it does on an idle M1 Max. Allocation counts are **near-deterministic
for a given code path**, which is the property that survives heterogeneous,
noisy, shared hardware where wall-clock cannot.

So the CI gate checks `mallocCountTotal` (backed by jemalloc, installed for
the benchmark job in
[commit `2d3565a`](https://github.com/8b-is/qwave/commit/2d3565a560c45004fbbaa54d29bc3c4799bccb87)):

```swift
let checkedMetrics: [BenchmarkMetric] = [
    .mallocCountTotal,
    .retainCount,
    .releaseCount,
    .retainReleaseDelta,
]
let tolerance: [BenchmarkMetric: BenchmarkThresholds] = [
    .mallocCountTotal: .init(relative: [.p90: 25.0]),
    .retainCount: .init(relative: [.p90: 5.0]),
    .releaseCount: .init(relative: [.p90: 5.0]),
    .retainReleaseDelta: .init(relative: [.p90: 5.0]),
]
```
— [`QwaveKitBenchmarks.swift L24-L35`](https://github.com/8b-is/qwave/blob/088f0680efcefca542d427af20184574e693085c/Benchmarks/Benchmarks/QwaveKitBenchmarks/QwaveKitBenchmarks.swift#L24-L35)

Two things happened to that config over time, and they tell the story:

* **It started as `mallocCountTotal` alone** (the suite landed in
  [commit `f3402ea`](https://github.com/8b-is/qwave/commit/f3402ea84d7bd3b808d55e9a64488832c315dd04)).
* **The three ARC metrics were added later** ([`dac7187`](https://github.com/8b-is/qwave/commit/dac7187919701d36b5fff2166bab89828f713bdd)),
  because `mallocCountTotal` misses ARC traffic — retain/release churn that
  never touches the heap allocator. They're near-deterministic in the same
  way, so they get the same treatment but a *tighter* 5% tolerance (ARC
  counts are more sensitive to change, so a looser leash would hide real
  drift).

The tolerance asymmetry is deliberate. 25% p90 on `mallocCountTotal` absorbs
allocator/toolchain drift across Xcode and macOS versions while a real 2×
allocation regression still fails. The ARC metrics get 5% because they don't
drift — identical code produces identical retain/release counts — so any
movement at all is a signal.

## What allocation counts catch — and what they can't

![What mallocCountTotal sees (extra allocations, leaked strings, unbounded growth) vs what it misses (out-of-process memory, instruction count, stalls)](assets/malloccount-sees-misses.svg)

Allocation counts are not a complete performance metric. They are a **CI-gate
metric** — narrow on purpose, chosen because they are the one thing that is
both (a) deterministic on shared hardware and (b) a reliable proxy for the
most common Swift regressions:

* **An extra allocation per call** — a new `String` intermediate, a
  `replacingOccurrences` that materializes a temporary, a collection that
  grows past its `reserveCapacity`. This is the single most common way Swift
  code gets slower, and it is exactly what `mallocCountTotal` catches.
* **A leaked string or temporary** — shows up as an allocation that used to
  be zero.
* **Unbounded collection growth** — sorting when you meant top-k, as in the
  [zero-allocation post](zero-allocation-text-on-the-keystroke-path.md).

What it *cannot* see is a list with named owners, and each miss is covered by
a dedicated tool rather than left unmeasured:

| Miss | Why `mallocCountTotal` can't see it | The tool that does |
|---|---|---|
| Out-of-process memory | WebContent lives in other processes | `proc_pid_rusage` ([memory post](measuring-memory-a-browser-doesnt-own.md)) |
| Instruction count / CPU work | `@inlinable` changes dispatch, not allocs | Instruments Time Profiler |
| Main-thread stalls | A stall allocates nothing | 50 ms heartbeat timer ([blocklist post](what-59657-blocking-rules-cost.md)) |

This is the part people miss: the value of a narrow metric is not that it is
complete, it is that it is *honest about what it measures*. Wall-clock
pretends to be complete and fails at the one job it has — being
deterministic. `mallocCountTotal` knows exactly what it is, and the gaps are
filled by instruments whose whole purpose is those gaps.

## Wall-clock isn't deleted; it's demoted

Wall-clock is still collected — every run records it — it is just **never
checked in CI**. Local profiling on an idle machine is where wall-clock
belongs: it tells you *whether* an optimization helped, in the one environment
where it can. The CI gate is where determinism belongs: it tells you *whether
anything broke*, in the environment you can't control.

The two instruments complement each other precisely because they measure
different things with different reliability. The mistake is using the noisy
one for the gate and being surprised when it flakes.

## Key takeaways

1. **A ±30% instrument cannot catch a 2× regression.** Wall-clock on shared
   runners measures the host, not your code.
2. **Allocation counts are near-deterministic for a given code path** — the
   property that survives noisy, shared, heterogeneous CI.
3. **One metric is not enough.** `mallocCountTotal` catches heap churn; the
   ARC metrics (retain/release/delta, 5% tolerance) catch everything the heap
   allocator never sees.
4. **A narrow metric is a feature, not a bug.** The misses have named owners
   (`proc_pid_rusage`, Instruments, heartbeat timers) instead of being hidden
   inside a vague wall-clock number.
5. **Deterministic for CI, wall-clock for development.** Never the other way
   around.

*Sister posts in this series:
[zero-allocation text on the keystroke path](zero-allocation-text-on-the-keystroke-path.md) ·
[what 59,657 blocking rules cost](what-59657-blocking-rules-cost.md) ·
[the measured cost of a Swift module boundary](measured-cost-of-a-swift-module-boundary.md) ·
[measuring memory a browser doesn't own](measuring-memory-a-browser-doesnt-own.md).*
