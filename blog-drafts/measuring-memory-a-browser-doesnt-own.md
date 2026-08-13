---
title: "Measuring memory a browser doesn't own"
status: draft
date: 2026-08-13
tags: [swift, performance, webkit, memory, macos, profiling]
measured_on: "Apple M1 Max (8 P-cores / 2 E-cores), 64 GB unified memory, macOS 26.4, Xcode 16.4. Release build, proc_pid_rusage over WebContent pid-set difference."
---

# Measuring memory a browser doesn't own

*Long-form engineering post. Illustrations generated via the entheai engine
(`vaked` provider, deepseek-v3.2) and hand-polished for correctness.*

There is a category of memory that your own process cannot see, and the
biggest one in a WebKit browser happens to be the one that matters most for
battery: the memory behind every tab. When Qwave hibernates a tab, it
destroys the `WKWebView` — and the memory that frees is not in Qwave's
process at all. It lives in `com.apple.WebKit.WebContent`, one out-of-process
renderer per site, and it vanishes the moment WebKit tears that process
down.

Every in-process profiling tool is structurally blind to this. This post is
about the one trick that isn't: measuring the process *tree* with
`proc_pid_rusage`, and the two numbers it bought us — **137 MB reclaimed per
three tabs**, and a **190–305 ms** wake-to-interactive bill that the memory
costs.

## The problem: your memory gauge is lying to you

Fire up Xcode's memory gauge on Qwave, hibernate ten tabs, and watch. The
gauge barely moves. That is not a bug in hibernation — it is a bug in the
gauge's model of the world. WebKit renders every page in an out-of-process
content process (one or more per tab/site), plus shared networking and GPU
processes. The app process — the one your heap inspector, `vmmap`, and
`task_info` are pointed at — owns almost none of the interesting memory.

![Diagram: Qwave app process vs three out-of-process WebContent processes that hold the tab memory](assets/hibernation-process-tree.svg)

So the first thing we had to do was *not* write a benchmark. It was to admit
that the obvious tooling can't answer the question, and reach for the one API
that can talk to another process: `proc_pid_rusage`, which reads the same
`ri_phys_footprint` number Activity Monitor shows, for any pid on the system.

## Method: snapshot the tree, then subtract

The measurement lives in `HibernationReclaimTests`
([`L18-L57`](https://github.com/8b-is/qwave/blob/088f0680efcefca542d427af20184574e693085c/Packages/QwaveKit/Tests/BrowserCoreTests/HibernationReclaimTests.swift#L18-L57)),
landed in
[commit `ba8caf0`](https://github.com/8b-is/qwave/commit/ba8caf0bc09614bfa980364937236902f518ebb5).
The core is two small functions. First, enumerate every WebContent pid on the
machine:

```swift
static func webContentPIDs() -> Set<pid_t> {
    var size = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
    guard size > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.size + 64)
    size = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    let count = Int(size) / MemoryLayout<pid_t>.size
    var result: Set<pid_t> = []
    var nameBuffer = [CChar](repeating: 0, count: 1024)
    for pid in pids.prefix(count) where pid > 0 {
        nameBuffer[0] = 0
        _ = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        if String(cString: nameBuffer) == "com.apple.WebKit.WebContent" {
            result.insert(pid)
        }
    }
    return result
}
```
— [`L22-L38`](https://github.com/8b-is/qwave/blob/088f0680efcefca542d427af20184574e693085c/Packages/QwaveKit/Tests/BrowserCoreTests/HibernationReclaimTests.swift#L22-L38)

Then sum the physical footprint over a set of pids:

```swift
static func footprint(of pids: Set<pid_t>) -> UInt64 {
    var total: UInt64 = 0
    for pid in pids {
        var usage = rusage_info_current()
        let ok = withUnsafeMutablePointer(to: &usage) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reptr in
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, reptr)
            }
        }
        if ok == 0 {
            total += usage.ri_phys_footprint
        }
    }
    return total
}
```
— [`L42-L56`](https://github.com/8b-is/qwave/blob/088f0680efcefca542d427af20184574e693085c/Packages/QwaveKit/Tests/BrowserCoreTests/HibernationReclaimTests.swift#L42-L56)

Two details matter more than they look:

* **The set difference.** We snapshot the machine's WebContent pids *before*
  creating any web views, then subtract that baseline from the set we see
  after. Without that, a stray Safari window on the same Mac would be counted
  as Qwave's memory. This is the difference between "measure the tree" and
  "measure the tree *we* grew."
* **`ri_phys_footprint`, not RSS.** `proc_pid_rusage` gives the number
  Activity Monitor actually shows — the one people will trust and reproduce.
  Reporting a different metric than the one the user sees in the GUI is how
  perf claims quietly lose their audience.

## The fixture: memory you can reproduce

Hibernation numbers are only meaningful if the pages hold deterministic
memory. The test writes three *ballast* pages — local files, ~24 MB of
JS-held doubles plus 2,000 DOM nodes each ([`L63-L83`](https://github.com/8b-is/qwave/blob/088f0680efcefca542d427af20184574e693085c/Packages/QwaveKit/Tests/BrowserCoreTests/HibernationReclaimTests.swift#L63-L83)):

```js
window.ballast = new Array(3 * 1024 * 1024).fill(0.123456789 + 0);
for (let i = 0; i < 2000; i++) {
    const p = document.createElement('p');
    p.textContent = 'paragraph ' + i + ' of ballast page 0';
    document.body.appendChild(p);
}
document.title = 'ready-0';
```

Real-world pages vary wildly; the ballast is deliberately synthetic and
deterministic so the test has a floor it can assert against, not a number it
hopes for. Local files only — no network, no ads, no nondeterminism, so it is
CI-safe.

## The measurement and the result

The test loads three tabs, waits for `title == "ready-N"` (the DOM-ready
signal), lets allocations settle, then ([`L108-L158`](https://github.com/8b-is/qwave/blob/088f0680efcefca542d427af20184574e693085c/Packages/QwaveKit/Tests/BrowserCoreTests/HibernationReclaimTests.swift#L108-L158)):

1. snapshots `ourPIDs` (the tree we grew),
2. sums the "before" footprint,
3. hibernates every tab through `TabHibernator`
   ([`L19-L45`](https://github.com/8b-is/qwave/blob/088f0680efcefca542d427af20184574e693085c/Packages/QwaveKit/Sources/BrowserCore/TabHibernator.swift#L19-L45)),
   which snapshots the placeholder, captures `interactionState`, and tears
   the web view down,
4. re-sums after WebKit asynchronously reaps the content processes.

| Metric | Value |
|---|---|
| WebContent processes for 3 ballast tabs | 3 |
| Combined footprint before | **137.0 MB** |
| Combined footprint after | **0.0 MB** — processes terminated |
| Reclaimed | **45.7 MB per tab** |

![Bar chart: 137 MB before hibernation → 0 MB after (processes terminated, not trimmed)](assets/hibernation-reclaim.svg)

The thing worth pausing on: **after is 0.0 MB, not "less."** Hibernation does
not trim a tab's footprint — it kills the content process *entirely*, so the
reclaim is the whole per-tab WebContent footprint, not a partial garbage
collection. That is a categorically different claim from "tabs use less
memory when backgrounded," and it is the reason the number is worth measuring
precisely: the regression you'd care about is a leak where the hibernator
retains a live `WKWebView` and the process never dies, which shows up as
`after` refusing to fall — not as a few stray megabytes.

## The other side of the trade: wake-to-interactive

Hibernation isn't free. Killing the content process means waking a tab
requires spawning a *new* one. The test measures the full interval, from
`hibernator.restore()` to the page's DOM-ready signal
([`L169-L186`](https://github.com/8b-is/qwave/blob/088f0680efcefca542d427af20184574e693085c/Packages/QwaveKit/Tests/BrowserCoreTests/HibernationReclaimTests.swift#L169-L186)):

| Phase | Time |
|---|---|
| WebContent process spawn | ~100–200 ms |
| WKWebView construction + state restore | ~50 ms |
| Page load + JS execution + DOM ready | ~100–200 ms |
| **Wake-to-interactive (canonical)** | **190–305 ms** |

![Stacked bar: wake-to-interactive 190–305 ms = process spawn + WKWebView construct + page load](assets/hibernation-wake-latency.svg)

A confession baked into the draft's revision history, because it is exactly
the kind of mistake that makes performance numbers untrustworthy: an earlier
session reported **138 ms**. That number was real — but it measured only
`TabHibernator.restore()`'s own `os_signpost` interval, i.e. the WKWebView
construction and state-restore phase, *not* the process spawn and page load
that follow it. The canonical, user-facing number is the full interval:
**190–305 ms**. Both measurements are honest about what they contain; the sin
is presenting the narrower one as the whole. When you define a latency metric
in a browser, the process-spawn boundary is either inside your measurement or
it is a lie you're telling yourself.

## The knob that's wired but not yet measured: warmProcessCount

If process spawn is ~100–200 ms of the wake bill, the obvious optimisation is
to keep a spare WebContent process warm. Qwave has the knob: `EnergyPolicy`
carries a `warmProcessCount` (1 at `.normal`, 0 at `.conserve` and
`.critical` —
[`EnergyGovernor.swift L87-L111`](https://github.com/8b-is/qwave/blob/088f0680efcefca542d427af20184574e693085c/Packages/QwaveKit/Sources/BrowserCore/EnergyGovernor.swift#L87-L111)),
and `WebViewFactory` now turns it into a held `WKProcessPool`
([`L35-L41`](https://github.com/8b-is/qwave/blob/088f0680efcefca542d427af20184574e693085c/Packages/QwaveKit/Sources/BrowserCore/WebViewFactory.swift#L35-L41),
wired in
[commit `23f88e6`](https://github.com/8b-is/qwave/commit/23f88e6519cda31063f802829b00a3f46f172524)).

```swift
/// Number of spare WebContent processes to keep warm for fast wake.
/// Zero at .conserve and .critical tiers; 1 at .normal is a memory-vs-latency
/// tradeoff — keeping one process warm costs ~45 MB but saves ~100-200 ms
/// on wake-to-interactive.
public var warmProcessCount: Int
```

But here is the honest part, and the reason this belongs in a post about
*measuring*: the **"~45 MB for ~100–200 ms" tradeoff in that doc comment is
aspirational, not measured.** No test drives a warm process through a wake
and timestamps it. The reclaim floor *is* measured (the test asserts >50%
reclaim and >10 MB/tab); the warm-path latency saving *is not*. A knob being
wired is not the same as a knob being justified. Until there is a
warm-process wake measurement, treat the 100–200 ms saving as a hypothesis
with a plausible mechanism — and notice how much of this post's confidence
comes precisely from having refused that shortcut on the reclaim side.

## What didn't work

A short list, because it is the map of everything *not* to reach for:

* **`task_info`** — sees only the calling process. Structurally incapable of
  seeing WebContent.
* **`package-benchmark` / any in-process harness** — same wall: it benchmarks
  the process it runs in. WebKit's renderers are other processes.
* **`vmmap <pid>`** — the pids are separate processes; you'd have to already
  know which ones, and you'd still be reconstructing the tree by hand.
* **Xcode Memory Gauge** — shows the app process; WebKit's helpers are
  grouped only under the "responsible process" view, which still doesn't give
  you a per-test number.

The general rule that falls out: **if your web content lives in out-of-process
renderers — WKWebView, Chromium's `--site-per-process` — the only correct way
to measure the memory impact of a tab-lifecycle decision is to measure the
process tree.** `proc_pid_rusage` with set-difference filtering is the
simplest reliable way to do it on macOS.

## Reproduce it

```bash
git clone https://github.com/8b-is/qwave.git && cd qwave
xcodebuild test -scheme QwaveKit \
  -only-testing:BrowserCoreTests/HibernationReclaimTests
```

The test prints its own numbers (`[hibernation-reclaim] processes=… before=…
after=… reclaimed=…`) and the wake latency. The protocol for a *manual*,
whole-app measurement (idle machine, `footprint --json`, a fixed tab set) is
documented in
[`docs/ENERGY.md`](https://github.com/8b-is/qwave/blob/088f0680efcefca542d427af20184574e693085c/docs/ENERGY.md).

## Key takeaways

1. **Measure the tree, not the process.** The memory that matters most in a
   WebKit browser is out-of-process, and every in-process tool is blind to it.
2. **`proc_pid_rusage` + `ri_phys_footprint` + set-difference** is the
   minimum viable process-tree measurement on macOS — and it reports the same
   number Activity Monitor shows.
3. **Define the latency metric precisely.** 138 ms was "construction only";
   190–305 ms is "construction + spawn + load". Only the latter is the number
   a user feels, and the process-spawn boundary belongs inside it.
4. **Terminate ≠ trim.** Hibernation reclaims the *entire* content process,
   which is why the after-number is 0.0 MB, and why the regression test can
   assert a hard floor instead of a fuzzy one.
5. **A wired knob is not a measured knob.** `warmProcessCount` exists and
   works; its ~100–200 ms benefit is still a hypothesis until someone
   timestamps a warm wake.

*Sister posts in this series:
[zero-allocation text on the keystroke path](zero-allocation-text-on-the-keystroke-path.md) ·
[what 59,657 blocking rules cost](what-59657-blocking-rules-cost.md) ·
[why we count allocations not wall clock](why-we-benchmark-allocations-not-wall-clock.md) ·
[the measured cost of a Swift module boundary](measured-cost-of-a-swift-module-boundary.md).*
