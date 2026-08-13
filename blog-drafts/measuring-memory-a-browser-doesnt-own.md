---
title: "Measuring memory a browser doesn't own"
status: draft
date: 2026-08-13
tags: [swift, performance, webkit, memory, macos]
measured_on: "Apple M1 Max (8 P-cores / 2 E-cores), 64 GB unified memory, macOS 26.4, Xcode 16.4"
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
| 3 tabs loaded | 135.2 MB | 0.0 MB | −135.2 MB |
| Per tab | 45.1 MB | — | 45.1 MB/tab |
| Wake-to-interactive | — | 305 ms | — |

## What didn't work

- `task_info` — sees only the calling process.
- `package-benchmark` — in-process, cannot measure WebContent children.
- `vmmap <pid>` — WebContent pids are separate processes.
- Xcode Memory Gauge — same limitation.

## Key takeaway

If your web content lives in out-of-process renderers (WKWebView, Chromium's --site-per-process), the only way to measure the full memory impact of tab lifecycle decisions is to measure the process tree. `proc_pid_rusage` with set-difference filtering is the simplest reliable approach on macOS.