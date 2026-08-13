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

## What We Chose NOT to Optimize

| Area | Reason |
|---|---|
| Crypto (VPNKit PostQuantum) | Constant-time ML-KEM compare is a security boundary. Off-limits per policy. |
| ShieldsPolicy, HTTPSFirstUpgrader | Security-relevant parsing. Table-driven bypass tests must pass unchanged. |
| WireGuardKit | Vendored dependency. Pinned at `2fec12a6e1f6`. |
| Module collapse | The 6-way split is deliberate: build times, testability, `QwaveTunnelKit` boundary. |
| FTS5 for history search | Would fix the `LIKE %query%` full table scan, but adds a dependency and migration complexity. Deferred. |