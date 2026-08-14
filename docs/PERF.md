# Qwave performance — Speedometer 3 methodology

Qwave's chrome (tab strip, energy governor, shields, navigation) runs on the
main thread alongside the page WebKit is loading. A browser's **chrome tax** is
the main-thread work it does *during* a page load that the page itself did not
ask for. Speedometer 3 is how we measure it, and this doc is the contract for
doing so honestly.

> **Measurement is on-Mac, by a human.** A GUI browser benchmark needs a real
> display, WindowServer, and GPU — it cannot run headlessly or in CI. Every
> Score number in a perf PR comes from `scripts/benchmark.sh` run on a Mac and
> pasted into the PR. CI only guards the committed anchor + parser from drift
> (the non-blocking `perf-anchor` job). No Score in this repo was produced by
> an agent; none ever should be.

## The committed baseline

`Benchmarks/Speedometer/baseline.json` is the comparison anchor — a 10-iteration
Speedometer 3 run of Qwave. Headline numbers (`node Benchmarks/Speedometer/parse.mjs baseline.json`):

| Metric | Value | Direction |
|---|---|---|
| **Score** | 23.88 | higher is better |
| **Geomean** | 42.71 ms | lower is better |
| **Iteration-0 total** | 76.74 ms | — |
| **Steady-state median** | 49.57 ms | — |
| **Cold-start gap** | **+54.8 %** | target: within 25% |

Two findings drive the phase:

1. **Cold start is the biggest single lever.** Iteration 0 is ~55% slower than
   steady state, and Speedometer's Score *includes* iteration 0 — worth roughly
   a full Score point. Do not report warm-only numbers; the harness reports both.
2. **Something injects sporadic 14–56 ms main-thread pauses.** Flat sub-tests
   show single wild outliers (e.g. Angular `DeletingAllItems/Async`: nine ~0.78 ms
   samples + one 15.96 ms). That periodicity points at Qwave's own timers.

Engine-bound suites (`TodoMVC-jQuery`, `React-Stockcharts-SVG`) are WebKit's
cost, not ours — they are flagged `engineBound` in the baseline and are not this
phase's target. The number to move is **(Safari − Qwave) on the same machine**:
that delta is the chrome tax. If Safari scores the same, the machine/engine is
the ceiling and the phase re-scopes to cold start + variance only.

## The harness

```sh
QWAVE_APP=/path/to/Qwave.app \
QWAVE_PROFILE_DIR="$HOME/Library/Application Support/Qwave" \
scripts/benchmark.sh -n 5
```

- **Fresh profile per run** (the script moves your profile aside and restores it
  on exit — `QWAVE_PROFILE_DIR` is required and has no default, so nothing is
  deleted by accident).
- **Energy governor ACTIVE** — no tier pinning, no benchmark-special flags. A run
  that disables the energy timer or pins `.normal` is cheating *and* hides
  regressions; the harness deliberately passes no such flag.
- Exports land in `Benchmarks/Speedometer/runs/` (gitignored); it reports the
  **median** Score across runs and the per-run delta vs baseline.

## Instrumentation (os_signpost)

`QwaveSignposts` (in `QwaveSupport/Log.swift`) exposes one signposter per
category on subsystem `is.8b.qwave`, so an Instruments **Points of Interest**
capture during a Speedometer run groups the chrome-tax suspects as intervals:

| Interval | Category | Where | Convicts |
|---|---|---|---|
| `energy-tick` | energy | `AppDelegate.energyTick()` | the 30 s foreground pause |
| `chrome-refresh` | browser | `BrowserWindowController.refreshChromeState()` | per-KVO-tick rebuilds |
| `applyLists` | shields | `ShieldsDirector.applyLists` | redundant rule-list teardown |
| `makeWebView` | coldstart | `WebViewFactory.makeWebView` | iteration-0 cold-start cost |

Run Speedometer under Instruments' Time Profiler + Points of Interest, and **fix
only what the trace convicts** — the ledger below is informed prediction until a
trace confirms it.

## Suspect ledger (from the investigation fan-out)

| # | Suspect | Verdict | Fix (feature-preserving) |
|---|---|---|---|
| 1 | Chrome re-render on every KVO tick (`estimatedProgress` drives no visible chrome, yet rebuilds the whole tab-model array each tick) | **confirmed** | coalesce refresh to one per runloop turn (dirty-flag + `DispatchQueue.main.async`); the per-item `TabBarView` diff is deferred (drag-reorder index-capture hazard) |
| 2 | 30 s energy tick on the main queue awaiting `requestMediaPlaybackState` per tab | **confirmed** | yield the tick while the frontmost tab was active/loading recently; never hibernate while the key tab `isLoading`; skip the media probe for non-hibernatable tabs. **Guardrail: "ticks resume when idle" test** |
| 3 | `ShieldsDirector.applyLists` does `removeAllContentRuleLists()` + re-add on every main-frame nav | **confirmed** | cache the attached list set by `WKContentRuleList` **object identity** (never by policy bools — that caches "ads on" before the list exists) and no-op when identical |
| 4 | Synchronous SQLite history write on the main actor in `didFinish` | **acquitted** | already fixed — `recordVisit` is `async`, `HistoryStore`/`SQLiteDatabase` are actors; no main-thread write remains |
| 5 | Per-tab `WKWebViewConfiguration` / cold process pool | **partly** | a shared `warmPool` already exists, but `setWarmProcessCount(1)` only fires ~30 s post-launch — warm it **before** the first window; prewarm a hidden `about:blank` view at idle (gated to `.normal`, torn down under conserve/critical). WKProcessPool is legacy on macOS 14+ — cite current WebKit before relying on pooling |
| 6 | Rule-list compile + VPN refresh block first-tab creation at launch | **partly** | open the first window immediately; warm shields + VPN concurrently. Guard the shields-bypass risk for a network homepage |

## Definition of Done (per the kickoff)

1. Signpost-trace evidence for each suspect: confirmed-and-fixed, or acquitted-with-numbers. No speculative optimization without a before/after trace.
2. Iteration-0 total within 25% of steady state (from +55%).
3. Zero chrome-injected pauses > 10 ms during a run (signposts prove the tick + refresh stay off the hot path).
4. Chrome tax vs Safari measured and reported.
5. Before/after median Score (N ≥ 5), harness + baseline committed, non-blocking CI perf lane.
6. All gates hold (malloc, ARC, format, Periphery); **battery posture unregressed** — hibernation/energy still fire when genuinely idle (the "resumes when idle" test is part of the energy-tick fix).

## Anti-cheat rules

- Nothing keyed to Speedometer's origin or URL; no disabling shields/features for
  benchmark pages. Every fix is a real-usage win or it doesn't ship.
- The energy-tick fix is "yield to foreground activity," never "stop ticking" —
  the battery story is the product, not a benchmark casualty.
- Speedometer counts iteration 0; always report cold and warm.
- Process-sharing changes must not weaken container isolation (which lives in
  `WKWebsiteDataStore(forIdentifier:)`, not the pool); the cookie-isolation test
  stays green.
