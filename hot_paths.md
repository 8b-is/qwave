# Hot Paths — Qwave Performance Map

> Measured 2026-08-13 on Apple M1 Max (8 P-cores / 2 E-cores, 64 GB unified memory, macOS 26.4, Xcode 16.4). Updated as optimizations land.

---

## Ranked by User-Facing Impact

### 1. Keystroke Path — Omnibox Parse + Suggestion

**Files:** `OmniboxParser.swift`, `OmniboxSuggester.swift`, `HistoryStore.swift`

**Runs on:** Every keystroke in the address bar.

| Sub-path | mallocCountTotal | Status |
|---|---|---|
| `OmniboxParser.parse` (3 cases) | 30 | Stable — WebURL parser inherent cost |
| `OmniboxSuggester.suggestions` (500 entries) | **1,011** | ⬇️ from 4,370 (M1) |
| `HistoryStore.entries(matching:)` (50k rows) | 391 | ⬇️ from 402-628 (M1) |

**Optimizations applied:**
- Bounded insertion sort (keep top N, discard rest) instead of full sort + prefix
- `replacingOccurrences` → prefix-drop with `Substring`
- `String` → `Substring` for `hostSansWWW` and `urlSansScheme`
- URL deduplication via `Set<String>` with `reserveCapacity`
- Prepared statement cache in `SQLiteDatabase` (skip `sqlite3_prepare_v2` on every call)
- Added `idx_history_url` and `idx_history_score` composite index

**Remaining:** `LIKE %query%` is still a full table scan. FTS5 would fix this but is deferred.

---

### 2. Blocklist Compile — First Launch

**Files:** `RuleListCompiler.swift`, `ShieldsDirector.swift`

**Runs on:** First launch (or list update). 59,657 rules.

| Metric | Measured | Budget |
|---|---|---|
| Cold compile | **2.84 s** | 15 s |
| Warm load | **13 ms** | 2 s |
| Artifact size | **27.7 MB** | 200 MB |
| Main-thread stall | **140 ms** | 500 ms |

**Optimizations applied:**
- JSON source cached in memory (read from disk once, released after compile)
- Background compile releases JSON from cache before Task captures it

**Note:** The 19.66 s measurement in the first run was an artifact of a background `xcodebuild` consuming CPU. Real measurement is 2.84 s.

---

### 3. Hibernation — Memory Reclaim

**Files:** `HibernationReclaimTests.swift`, `HibernationController.swift`, `TabHibernator.swift`

**Runs on:** Tab hibernation cycle.

| Metric | Measured | Floor |
|---|---|---|
| Content-process reclaim | **135.2 MB** (3 tabs, 45.1 MB/tab) | 10 MB/tab |
| Wake-to-interactive | **305 ms** | N/A |

**Note:** Wake-to-interactive is 305 ms, not the 138 ms stated in the original brief. The 138 ms may have been measured with simpler pages or a different machine.

---

### 4. Module Boundary Cost

**Files:** `OmniboxParser.swift`, `OmniboxSuggester.swift`

**Technique tried:** `@inlinable` + `@usableFromInline` on `OmniboxParser.parse` and `OmniboxSuggester.suggestions`.

**Result:** No measurable change in `mallocCountTotal`. The metric is allocation-count, not instruction-count, so `@inlinable`'s effect on specialization and ARC traffic is invisible to this benchmark. The change is kept because it enables the compiler to optimize the hot path further, but the impact is unquantified.

**Not tried:** `-cross-module-optimization` / `-enable-cmo` — requires build-system changes outside the SPM package scope. May be revisited.

---

## Profiling Method

- **Allocations:** `package-benchmark` with `mallocCountTotal` (deterministic, CI-assertable)
- **CPU:** `sample` (built-in macOS) for lightweight CPU profiling
- **Memory:** `vmmap` for process-level memory breakdown
- **Blocklist:** `WKContentRuleListStore` budget tests in `BlocklistPerformanceTests`
- **Hibernation:** `proc_pid_rusage` over WebContent pid-set difference

---

## Profiling Method

- **Allocations:** `package-benchmark` with `mallocCountTotal` (deterministic, CI-assertable)
- **ARC traffic:** `package-benchmark` with `.retainCount`, `.releaseCount`, `.retainReleaseDelta` (CI-assertable, captures what mallocCountTotal misses)
- **CPU:** `sample` (built-in macOS) for lightweight CPU profiling
- **Memory:** `vmmap` for process-level memory breakdown
- **Blocklist:** `WKContentRuleListStore` budget tests in `BlocklistPerformanceTests`
- **Hibernation:** `proc_pid_rusage` over WebContent pid-set difference

## Measurement Protocol

### Machine state requirements
Before running any benchmark, verify:
- **Thermal state:** `ProcessInfo.processInfo.thermalState == .nominal` (fail if not)
- **No background builds:** `pgrep -fl xcodebuild` returns empty (fail if running)
- **Load average:** `< 2.0` on 8-core machine (warn if exceeded)
- **No other browsers/apps with significant WebKit usage** (warn)

A benchmark run on an unquiesced machine is rejected, not recorded. The 19.66 s blocklist compile from session 1 should have been rejected — it was a background `xcodebuild` artifact, not a real measurement.

### Variance reporting
- Run N ≥ 5 iterations per benchmark
- Report median, p90, and spread (p90-p50)
- Fail if relative variance (p90-p50)/median exceeds 25% — high variance means the number is meaningless
- A single sample is not a measurement

### CI gates
| Metric | Deterministic | CI-checked | Tolerance | Notes |
|---|---|---|---|---|
| `mallocCountTotal` | ✅ Yes | ✅ Yes | 25% p90 | Primary allocation gate |
| `retainCount` | ✅ Yes | ✅ Yes | 5% p90 | ARC traffic gate (observed variance ~0%) |
| `releaseCount` | ✅ Yes | ✅ Yes | 5% p90 | ARC traffic gate (observed variance ~0%) |
| `retainReleaseDelta` | ✅ Yes | ✅ Yes | 5% p90 | ARC cycle detection (observed variance ~0%) |
| Wall-clock | ❌ No | ❌ No | — | Recorded for trends, not gated |
| CPU time | ❌ No | ❌ No | — | Recorded for trends, not gated |

ARC gates tightened from 25% to 5% after measuring observed run-to-run variance
at ~0% for all 5 benchmarks. The 25% flat tolerance was loose enough to hide
a real regression. 5% gives a small cushion for allocator/toolchain drift while
keeping the gates meaningful.

### Wake-to-interactive canonical definition
Time from `hibernator.restore()` to `restored.title == "ready-0"` (first paint with page content). Includes: WebContent process spawn, WKWebView construction, interactionState restoration, and page load. The process spawn boundary is explicitly inside the measurement.

---

## What We Chose NOT to Optimize

| Area | Reason |
|---|---|
| Crypto (VPNKit PostQuantum) | Constant-time ML-KEM compare is a security boundary. Off-limits per policy. |
| ShieldsPolicy, HTTPSFirstUpgrader | Security-relevant parsing. Table-driven bypass tests must pass unchanged. |
| WireGuardKit | Vendored dependency. Pinned at `2fec12a6e1f6`. |
| Module collapse | The 6-way split is deliberate: build times, testability, `QwaveTunnelKit` boundary. |
| FTS5 for history search | Would fix the `LIKE %query%` full table scan, but adds a dependency and migration complexity. Deferred. |