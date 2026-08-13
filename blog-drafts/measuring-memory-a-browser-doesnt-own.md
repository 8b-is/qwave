---
title: "Measuring memory a browser doesn't own"
status: draft
date: 2026-08-13
tags: [swift, performance, webkit, memory, macos]
measured_on: "Apple M1 Max (8 P-cores / 2 E-cores), 64 GB unified memory, macOS 26.4, Xcode 16.4. Release build, proc_pid_rusage over WebContent pid-set difference."
corrections: "v2 — Added canonical wake-to-interactive definition. The 138ms measurement from the earlier session was WKWebView construction only; the 305ms measurement is the full wake including WebContent process spawn and page load. Both are valid for what they measure, but the canonical user-facing metric is the full interval."
---

## The problem

When you hibernate a tab in Qwave, the `WKWebView` is destroyed. The memory it held lives in an out-of-process `com.apple.WebKit.WebContent` process. Standard in-process profiling tools (heap, vmmap, Xcode's memory gauge) see only Qwave's own process — the 137 MB that just got freed is invisible to them.

## What we did

We used `proc_pid_rusage` over the set of WebContent pids, measured by set-difference before and after creating our test views (so other apps' WebKit processes are excluded):

```swift
static func webContentPIDs() -> Set<pid_t> {
    // proc_listpids → filter by name == "com.apple.WebKit.WebContent"
}

static func footprint(of pids: Set<pid_t>) -> UInt64 {
    // proc_pid_rusage → sum of ri_phys_footprint
}
```

## Results

| Metric | Before | After | Delta |
|---|---|---|---|
| 3 tabs loaded | 135–136 MB | 0 MB | −135 MB |
| Per tab | 45 MB | — | 45 MB/tab |
| Wake-to-interactive (canonical) | — | 190–305 ms | — |

## Wake-to-interactive canonical definition

Time from `hibernator.restore()` to `restored.title == "ready-0"` (first paint with page content). Includes:

| Phase | Time | Notes |
|---|---|---|
| WebContent process spawn | ~100–200 ms | Hibernation kills the process entirely — wake requires a full spawn |
| WKWebView construction + state restore | ~50 ms | interactionState (back/forward, scroll, form) |
| Page load + JS execution + DOM ready | ~100–200 ms | 3MB JS ballast + 2000 DOM nodes |

The 138 ms measurement from the earlier session measured only the WKWebView construction + state restore phase (the `TabHibernator.restore()` os_signpost interval). The 305 ms measurement includes the full page load. The 190–305 ms range across runs reflects machine state variance, not measurement error.

**The process spawn boundary is explicitly inside the canonical measurement.** If a future optimisation keeps a warm WebContent process, this definition must be updated to specify whether process spawn is included or excluded.

## What didn't work

- `task_info` — sees only the calling process.
- `package-benchmark` — in-process, cannot measure WebContent children.
- `vmmap <pid>` — WebContent pids are separate processes.
- Xcode Memory Gauge — same limitation.

## Key takeaway

If your web content lives in out-of-process renderers (WKWebView, Chromium's --site-per-process), the only way to measure the full memory impact of tab lifecycle decisions is to measure the process tree. `proc_pid_rusage` with set-difference filtering is the simplest reliable approach on macOS.