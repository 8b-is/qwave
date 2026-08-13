# Energy & memory measurement plan

## Blocklist performance budget (measured 2026-08-13)

Method: `ShieldsTests/BlocklistPerformanceTests` — a fresh
`WKContentRuleListStore` directory per run; "cold" compiles the shipped
59,657-rule `easylist-compiled.json` from nothing, "warm" builds a new
store object on the same directory (a relaunch) so the content-hash
identifier must hit the on-disk cache; artifact size is the store
directory's byte total; main-thread stall is the largest gap observed in a
50 ms main-queue heartbeat during the compile. Machine: Apple Silicon
laptop, debug build (CI budgets are ~2× these numbers).

| Metric | Measured | Budget (test-enforced) |
|---|---|---|
| Cold compile (59,657 rules) | **2.8–3.1 s** | < 15 s |
| Warm load (relaunch, cache hit) | **~135 ms** | < 2 s, and < ½ cold |
| Compiled artifact on disk | **27.7 MB** (from 7.5 MB JSON) | < 200 MB |
| Max main-thread stall during compile | **~130 ms** | < 500 ms |

Launch impact: WebKit compiles off the app's main thread, and the compiled
list persists across launches, so a normal launch pays ~135 ms. A **list
content update** used to pay the full cold compile before first paint
(AppDelegate awaits `shields.prepare()`); since v0.3.x
`RuleListCompiler.availableList` serves the previous compiled version
immediately and swaps in the fresh compile in the background
(`testStaleListServedWhileFreshCompiles` pins this). Only a true first
launch — nothing compiled yet — waits the full ~3 s, which is the correct
trade for a shields-first browser: no unshielded first paint.


`EnergyGovernorTests` verifies hibernation *decisions*; nothing yet measures
the *memory actually reclaimed*. This documents how to measure it — and why
the obvious tooling can't.

## Why package-benchmark (and any in-process tool) can't measure this

Tab hibernation destroys `WKWebView`s. The memory that frees does not live
in Qwave's process: WebKit renders every page in out-of-process content
processes (`com.apple.WebKit.WebContent`, one or more per tab/site), plus
shared networking (`com.apple.WebKit.Networking`) and GPU
(`com.apple.WebKit.GPU`) processes. An in-process benchmark harness
(package-benchmark, XCTest `measure`, `task_info`) sees only Qwave's own
footprint, which barely moves on hibernation. Measuring the reclaim means
measuring the process *tree*.

## Measurement protocol

Attribution: macOS charges WebKit helper processes to the app via the
"responsible process" mechanism — Activity Monitor's memory pane groups them
under Qwave, and `footprint` can do the same aggregation.

1. Build Release, launch from a clean state, open a deterministic tab set
   (e.g. 10 tabs from a fixed URL list; let them finish loading, wait 30 s
   for caches to settle).
2. Baseline: `footprint Qwave` (sums the app; add `--json` for parsing) and
   `footprint $(pgrep -d, 'com.apple.WebKit')` for the helper tree — or in
   one shot, filter by responsibility:
   `ps -axo pid,rss,command | grep -E 'Qwave|WebKit'` for a cruder RSS view
   (`footprint`'s phys_footprint is the number Activity Monitor shows and
   the one to report).
3. Trigger hibernation: Tab menu → "Hibernate Inactive Tabs Now" (all tabs
   except the selected one).
4. Wait 30 s (WebKit tears content processes down asynchronously), then
   re-run the same sampling commands.
5. Report per-run: tab count, phys_footprint before/after for (a) the Qwave
   process, (b) the WebKit helper set, and the delta of (b) — that delta is
   the reclaim. Repeat 3× and use medians; content-process count is the
   sanity check (it should drop to ~1 per remaining live tab).

Automation note: steps 1–5 script cleanly with `open -a Qwave`, AppleScript
System Events for the menu action, and `footprint --json` parsing — but the
numbers are only meaningful on an otherwise idle machine, so this stays a
manual/semi-automated protocol rather than a CI job.

## What "good" looks like

A hibernated tab should release its content process(es) entirely; with N
hibernated tabs of ordinary pages, expect the helper-tree footprint to drop
by roughly the sum of those tabs' WebContent footprints (hundreds of MB for
ten heavy tabs). If the delta is near zero, suspect the hibernator is
keeping a live `WKWebView` reference (snapshot restore path) — that is a
regression even though every `EnergyGovernorTests` case still passes.
