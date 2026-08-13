---
title: "Why we benchmark allocations, not wall-clock"
status: draft
date: 2026-08-13
tags: [swift, performance, benchmarking, ci, macos]
measured_on: "N/A — methodology post, not a measurement."
---

## The problem

We run our benchmarks on Blacksmith `macos-15` shared runners (6 vCPU). Wall-clock time on these varies by ±30% or more depending on what else the host is running. A genuine optimisation can look like a regression, and a regression can hide behind noise.

## The solution

We use `package-benchmark`'s `mallocCountTotal` metric, backed by jemalloc. Allocation counts are near-deterministic for a given code path — the same code allocates the same number of times, regardless of CPU contention, thermal throttling, or ASLR.

```swift
let checkedMetrics: [BenchmarkMetric] = [.mallocCountTotal]
let tolerance: [BenchmarkMetric: BenchmarkThresholds] = [
    .mallocCountTotal: .init(relative: [.p90: 25.0])
]
```

The 25% p90 tolerance absorbs allocator/toolchain drift while a real regression (2× allocations) still fails.

## What wall-clock can't catch

- An optimisation that reduces allocations but is slower (unlikely, but possible with `@inlinable` I-cache pressure)
- A regression caused by a dependency update that adds one extra allocation per call
- The difference between sorting 500 entries and keeping 6 with a bounded heap

## What this misses

- **Out-of-process memory** — the hibernation claim (WebContent processes) can't be measured by an in-process benchmark. We use `proc_pid_rusage` for that.
- **Instruction count** — `@inlinable` may reduce instructions but not allocations. We use Instruments Time Profiler for CPU work.
- **Main-thread stalls** — blocklist compile happens off the main thread. We use a 50 ms heartbeat timer in the budget test.

## Key takeaway

`mallocCountTotal` is not a complete performance metric — it's a CI-gate metric. It catches the most common Swift regressions (extra allocations, leaked strings, un-bounded collections) with near-zero false-positive rate. Wall-clock is collected for local profiling but never checked in CI. The two tools complement each other: deterministic allocation counts for CI, wall-clock + Instruments for development.