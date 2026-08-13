---
title: "What 59,657 content-blocking rules actually cost"
status: draft
date: 2026-08-13
tags: [swift, performance, webkit, content-blocking, macos]
measured_on: "Apple M1 Max (8 P-cores / 2 E-cores), 64 GB unified memory, macOS 26.4, Xcode 16.4. Release build, cold compile with no cached artifact."
---

# What 59,657 content-blocking rules actually cost

*Long-form engineering post. Illustrations generated via the entheai engine
(`vaked` provider, deepseek-v3.2) and hand-polished for correctness.*

There is a number that only matters on the exact path where a browser is
allowed to be slow exactly once: the first paint. Qwave is a shields-first
browser — its identity is "block trackers before they ever run" — which means
its content blocker cannot be an afterthought that loads a moment *after* the
first page. It has to be active *before* anything renders. That constraint
turns a mundane operation, compiling a blocklist into a
`WKContentRuleList`, into the single most important number on the launch
path.

This post is the measurement of that number, and the one architectural
change — *stale-while-revalidate* — that made it stop mattering.

## The thing being compiled: not just "59,657 rules"

Qwave ships a snapshot of the EasyList blocklist as its built-in blocker
([commit `7928c38`](https://github.com/8b-is/qwave/commit/7928c3888c2d8cfa444078c315e4e698ef782ca4),
which replaced the 51-rule starter list). "59,657 rules" is the headline, but
it is three different kinds of thing bundled together:

| Kind | Count | What it does |
|---|---|---|
| URL/network block rules | 52,722 | `url-filter` + `block` actions |
| Native CSS-display-none cosmetics | 6,177 | hide elements without JS injection |
| Exceptions | 758 | `ignore-previous-rules` allowlists |

The snapshot is converted from upstream EasyList by AdGuard's
SafariConverterLib, run strictly as an external build-time tool — nothing GPL
is linked, vendored, or shipped, and the shipped artifact elects EasyList's
CC BY-SA 3.0 branch with attribution bundled. The pipeline and the license
boundary are documented in
[`docs/BLOCKLIST.md`](https://github.com/8b-is/qwave/blob/088f0680efcefca542d427af20184574e693085c/docs/BLOCKLIST.md).

On disk that list is a 7.5 MB JSON blob. WebKit compiles it into a binary
matcher. That compile is what we're measuring.

![Pipeline: 59,657 rules → 7.5 MB JSON → WKContentRuleListStore compile → 27.7 MB compiled artifact](assets/blocklist-pipeline.svg)

## Method: measure it like a regression, not a one-off

The numbers come from `BlocklistPerformanceTests`
([`L15-L165`](https://github.com/8b-is/qwave/blob/088f0680efcefca542d427af20184574e693085c/Packages/QwaveKit/Tests/ShieldsTests/BlocklistPerformanceTests.swift#L15-L165)),
introduced in
[commit `4d0b533`](https://github.com/8b-is/qwave/commit/4d0b533bd43c6559644d1e8eb5250b10c7a236fe).
It does four things, each against a **fresh** `WKContentRuleListStore`
directory per run so nothing is shared between the numbers:

1. **Cold compile** — nothing in the store; the full 59k-rule compile runs.
2. **Warm load** — a *fresh* store object and a *fresh* compiler on the *same*
   directory, simulating a relaunch. The content-hash identifier must hit the
   on-disk cache, not recompile.
3. **Artifact size** — the byte total of the compiled store directory.
4. **Main-thread stall** — a 50 ms main-queue heartbeat runs during the
   compile; the largest beat-to-beat gap is the stall.

The budgets are test-enforced at ~2× the measured numbers, deliberately:
slower CI runners should pass while a *pathological* regression — a rule
explosion, a cache defeat, the compile accidentally moving onto the main
thread — still fails:

```swift
private static let coldCompileBudget: TimeInterval = 15
private static let warmLoadBudget: TimeInterval = 2
private static let mainThreadStallBudget: TimeInterval = 0.5
```
— [budgets, `L18-L20`](https://github.com/8b-is/qwave/blob/088f0680efcefca542d427af20184574e693085c/Packages/QwaveKit/Tests/ShieldsTests/BlocklistPerformanceTests.swift#L18-L20)

## The numbers

| Metric | Measured | Budget | Notes |
|---|---|---|---|
| Cold compile (59,657 rules) | **2.8–3.1 s** | 15 s | first run on a loaded machine read 19.66 s — see below |
| Warm load (relaunch, cache hit) | **~135 ms** | 2 s | content-hash identifier hits the on-disk cache |
| Compiled artifact on disk | **27.7 MB** | 200 MB | from 7.5 MB of JSON |
| Max main-thread stall | **~130 ms** | 500 ms | WebKit compiles off the main thread |

![Bar chart: cold compile 2.84 s vs warm load 0.135 s — a 95% reduction](assets/blocklist-cold-vs-warm.svg)

Three things worth drawing out from that table.

**First, the cold compile is genuinely fine.** 2.8–3.1 seconds to turn 59,657
declarative rules into a native matcher is not something to optimize — it is
something to *respect* and leave alone. The reflex "3 seconds is slow, we
must be faster" is wrong here. It happens once, off the main thread, and it
buys you network-layer enforcement with zero per-page JavaScript.

**Second, the warm path is the number that actually governs the user
experience** — and it's ~135 ms. The identifier embeds a content hash of the
JSON (an FNV-1a, deliberately *not* `String.hashValue`, which isn't stable
across launches — [`RuleListCompiler.stableHash`, `L144-L151`](https://github.com/8b-is/qwave/blob/088f0680efcefca542d427af20184574e693085c/Packages/QwaveKit/Sources/Shields/RuleListCompiler.swift#L144-L151)),
so an unchanged bundle hits WebKit's on-disk cache and a changed bundle
misses it. That hash is the whole mechanism the stale-while-revalidate trick
below leans on.

**Third, the main-thread stall is the number that would matter most if it
were big.** It isn't — ~130 ms in a 50 ms heartbeat means the compile is
essentially never hogging the main queue, because WebKit does the work on its
own thread. This is the metric you add when you don't trust the platform;
the test exists to *catch the day we break it*, not because it's currently a
problem.

## The false positive that could have been a 15 s budget

The first cold-compile measurement was **19.66 seconds**. That is the kind of
number that sends you looking for a fundamental problem in WebKit, when the
actual problem was a background `xcodebuild` in a git worktree eating every
core on the machine. On a clean machine: 2.84 s.

This is the quietest lesson in the whole session and the easiest to skip:
**measure on an idle machine, or you will budget for the wrong thing.** A
19.66 s measurement would have justified a 40 s budget and a week of work
that solved nothing. The whole point of pinning budgets at ~2× measured (not
10×, not "whatever made CI green") is that an honest number makes a
regression *visible* as a failure instead of hiding it inside a sloppy
ceiling.

## The one real cost: a list update blocked first paint

For a normal launch, none of the above is a problem — warm load is ~135 ms.
The pain was a specific and rare-but-real case: **a list *update***. When the
bundled snapshot changes, the content hash changes, the cache misses, and the
app paid the full cold compile *before first paint* — because
`AppDelegate` awaited `shields.prepare()`, and `prepare()` used the
synchronous-compile path:

```swift
// BEFORE (commit 66a86ea) — a list update paid the full compile up front
public func prepare() async {
    do {
        adsList = try await compiler.compiledList(for: .adsAndTrackers)
        httpsUpgradeList = try await compiler.compiledList(for: .httpsUpgrade)
    } catch {
        QwaveLog.shields.error("Rule list compilation failed: ...")
    }
}
```

A user who updated the app now waited ~3 seconds — unshielded, or staring at
a blank window — because we decided correctness meant "the newest list before
anything draws." That trade is wrong. The previous list, which was blocking
99.9% of the same things *yesterday*, is strictly better than nothing. Serving
it immediately while the fresh one compiles is not a compromise; it is the
only answer that respects both the "shields-first" identity and the launch
budget.

The fix is `RuleListCompiler.availableList`
([`L80-L127`](https://github.com/8b-is/qwave/blob/088f0680efcefca542d427af20184574e693085c/Packages/QwaveKit/Sources/Shields/RuleListCompiler.swift#L80-L127)):

```swift
// AFTER — serve the stale list, compile fresh in the background, swap
let staleIdentifier = (await store.availableIdentifiers() ?? [])
    .first { $0.hasPrefix("\(list.rawValue)-") && $0 != identifier }
if let staleIdentifier, let stale = try? await store.contentRuleList(forIdentifier: staleIdentifier) {
    let jsonCopy = json
    jsonCache.removeValue(forKey: list)
    Task { @MainActor [weak self] in
        guard let self else { return }
        let fresh = try await self.compile(identifier: identifier, json: jsonCopy)
        self.cache[list] = fresh
        try? await self.store.removeContentRuleList(forIdentifier: staleIdentifier)
        onRefresh(fresh)
    }
    return stale
}
```
— [the stale-while-revalidate core, `L96-L120`](https://github.com/8b-is/qwave/blob/088f0680efcefca542d427af20184574e693085c/Packages/QwaveKit/Sources/Shields/RuleListCompiler.swift#L96-L120)

`prepare()` in `ShieldsDirector` now calls `availableList` and swaps the fresh
list in through the callback ([`L27-L36`](https://github.com/8b-is/qwave/blob/088f0680efcefca542d427af20184574e693085c/Packages/QwaveKit/Sources/Shields/ShieldsDirector.swift#L27-L36)),
and new navigations reconcile through `applyLists`, so the swap needs no push.

![Flow: app launch → previous version compiled? yes → serve stale immediately, compile fresh in background; no → wait for full compile](assets/blocklist-stale-while-revalidate.svg)

The consequence is worth spelling out precisely, because it's easy to wave
hands at "stale-while-revalidate" and miss what it bought:

* A **normal relaunch** — no update — was already ~135 ms; unchanged.
* An **update** — the case that used to cost ~3 s before first paint — is now
  ~135 ms (serve the previous list) plus a background compile whose only
  observable effect is the list swapping in, silently, seconds later.
* A **true first launch** — nothing compiled yet — *still* waits the full
  compile. That is deliberate and correct: there is no stale list to serve,
  and a shields-first browser does not do an unshielded first paint.

And because the superseded artifact is removed after the swap
([`L111`](https://github.com/8b-is/qwave/blob/088f0680efcefca542d427af20184574e693085c/Packages/QwaveKit/Sources/Shields/RuleListCompiler.swift#L111)),
the store doesn't grow a new 27.7 MB artifact on every version bump. This
whole behavior is pinned by `testStaleListServedWhileFreshCompiles`
([`L81-L133`](https://github.com/8b-is/qwave/blob/088f0680efcefca542d427af20184574e693085c/Packages/QwaveKit/Tests/ShieldsTests/BlocklistPerformanceTests.swift#L81-L133)),
including the async race where the removal completes *after* the refresh
callback.

## What didn't work (and one thing that worked less than expected)

* **Releasing the source JSON after compile.** This one is *half* a win. The
  compiler caches the 7.5 MB JSON in memory after the first read and releases
  it once compilation succeeds ([`L104-L105`](https://github.com/8b-is/qwave/blob/088f0680efcefca542d427af20184574e693085c/Packages/QwaveKit/Sources/Shields/RuleListCompiler.swift#L104-L105),
  landed with the omnibox work in
  [commit `15c1389`](https://github.com/8b-is/qwave/commit/15c1389aa0e2ccff5bf80cb85b62d7dcc6a2b6a9)).
  That's 7.5 MB of resident memory we no longer hold for the lifetime of the
  app. But the honest version: the *steady-state* memory of the blocker is
  dominated by WebKit's compiled bytecode matcher (that 27.7 MB artifact),
  not by the source JSON. The release was worth doing — it's free correctness
  — but it did not move the headline number.
* **Reducing the rule count.** We looked for deduplication opportunities.
  There aren't meaningful ones: the EasyList snapshot is already aggressively
  optimized upstream, and any reduction would trade coverage for a number
  that doesn't actually matter (see "the cold compile is fine" above). The
  correct response to "59,657 rules is a lot" turned out to be "measure it"
  rather than "shrink it".

## What I left on the table

* The stale path currently serves whatever version is in the store; if a
  genuinely broken list shipped, "stale" would be preferable in a way the code
  can't currently express. A version-floor guard (never serve a stale list
  older than N versions) is a future consideration, not a current risk.
* The cold compile is deliberately synchronous on true first launch. If
  first-launch time ever matters more than an unshielded paint, that trade
  flips — but I'd want a measured reason before changing it.
* The `RemoteBlocklistUpdater` runtime pipeline sits on top of this unchanged;
  its update cadence is a separate question from the compile cost and I
  deliberately didn't touch it here.

## Reproduce it

```bash
git clone https://github.com/8b-is/qwave.git && cd qwave
xcodebuild test -scheme QwaveKit \
  -only-testing:ShieldsTests/BlocklistPerformanceTests
```

The method and the numbers are documented in
[`docs/ENERGY.md`](https://github.com/8b-is/qwave/blob/088f0680efcefca542d427af20184574e693085c/docs/ENERGY.md);
the "before" state is the parent commit
[`66a86ea`](https://github.com/8b-is/qwave/commit/66a86ea51f5ed6d3458c7a61dfe97716cc7a8399),
and the feature commit is
[`4d0b533`](https://github.com/8b-is/qwave/commit/4d0b533bd43c6559644d1e8eb5250b10c7a236fe).

## Key takeaways

1. **Measure the number you actually ship, not the number that's scary.**
   Cold compile was never the problem; a list update blocking first paint
   was. The fix targeted the real case.
2. **Stale-while-revalidate is the correct primitive for "don't make the
   user wait for the newest thing."** Content blockers, config, caches —
   anything where yesterday's version is 99% as good and today's version
   will be there in seconds.
3. **A content hash in the identifier is what makes the cache correct and
   the stale path possible.** Stable hash, not `hashValue`.
4. **Budget ~2× measured, and measure on an idle machine.** A 19.66 s false
   positive nearly justified a 40 s budget and a week of phantom work.
5. **Releasing a 7.5 MB JSON is free correctness but not a headline win.**
   The compiled artifact, not the source, dominates steady-state memory.

*Sister posts in this series:
[zero-allocation text on the keystroke path](zero-allocation-text-on-the-keystroke-path.md) ·
[measuring memory a browser doesn't own](measuring-memory-a-browser-doesnt-own.md) ·
[why we count allocations not wall clock](why-we-benchmark-allocations-not-wall-clock.md) ·
[the measured cost of a Swift module boundary](measured-cost-of-a-swift-module-boundary.md).*
