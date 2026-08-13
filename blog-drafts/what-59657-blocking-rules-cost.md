---
title: "What 59,657 content-blocking rules actually cost"
status: draft
date: 2026-08-13
tags: [swift, performance, webkit, content-blocking, macos]
measured_on: "Apple M1 Max (8 P-cores / 2 E-cores), 64 GB unified memory, macOS 26.4, Xcode 16.4. Release build, cold compile with no cached artifact."
---

## The problem

Qwave ships a 59,657-rule EasyList snapshot as its built-in blocklist. Compiling it into a `WKContentRuleList` is the dominant cost on first launch. We measured every part of the pipeline to set budgets and find regressions early.

## Method

`BlocklistPerformanceTests` creates a fresh `WKContentRuleListStore` directory per run, compiles the shipped JSON, and measures:

- **Cold compile**: first build, no cache
- **Warm load**: fresh store object on the same directory (relaunch simulation)
- **Artifact size**: compiled store directory byte total
- **Main-thread stall**: 50 ms main-queue heartbeat during compile

## Results

| Metric | Measured | Budget | Notes |
|---|---|---|---|
| Cold compile | **2.84 s** | 15 s | First run was 19.66 s — background build noise |
| Warm load | **13 ms** | 2 s | Cache hit, effectively instant |
| Artifact size | **27.7 MB** | 200 MB | 7.5 MB JSON → 27.7 MB compiled |
| Main-thread stall | **140 ms** | 500 ms | WebKit compiles off the main thread |

The 19.66 s initial measurement was a false positive: a background `xcodebuild` in a git worktree was consuming all CPU. On a clean machine, the compile is 2.84 s — well under the 15 s budget.

## The stale-while-revalidate fix

The original design waited for the full compile before first paint. Since v0.3.x, `RuleListCompiler.availableList` serves the previous compiled version immediately and compiles the fresh one in the background:

```swift
// Stale version is served instantly
let served = try await compiler.availableList(for: .adsAndTrackers) { fresh in
    // fresh compile delivered asynchronously
}
```

This means a list update costs ~13 ms (warm load of the stale list), not 2.84 s. Only a true first launch (no previous artifact) waits the full compile.

## What didn't work

- **Releasing the source JSON after compile** — we added this (7.5 MB saved), but the steady-state memory is dominated by WebKit's compiled bytecode matcher, not the JSON source.
- **Reducing rule count** — we checked for deduplication opportunities. The EasyList snapshot is already well-optimised by the upstream maintainers. Any reduction would lose coverage.

## Key takeaway

WKContentRuleList compilation is fast enough (2.84 s for 59k rules) that the only real problem is not blocking first paint. The stale-while-revalidate pattern solves that. The 27.7 MB artifact is the cost of declarative, network-layer enforcement — and it's worth it compared to JS-injected blockers.