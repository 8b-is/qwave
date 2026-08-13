# Swift Tips & Tricks — Qwave Performance Patterns

> Patterns discovered and validated during Qwave's performance work. Verified against Swift 5.10, macOS 14.0+ deployment target, Apple Silicon.

---

## Strings — Avoid Intermediate Allocations

### ✅ `Substring` for slicing, not `String`

```swift
// Bad: allocates a new String
let hostSansWWW = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host

// Good: Substring keeps the original String's lifetime
let hostSansWWW = host.hasPrefix("www.") ? host[host.index(host.startIndex, offsetBy: 4)...] : Substring(host)
```

**Why:** `Substring` is a view into the original String's storage. No copy, no allocation. Only promote to `String` when you need to pass to an API that requires it.

### ✅ Strip scheme with prefix drop, not `replacingOccurrences`

```swift
// Bad: two intermediate String allocations per entry
let urlSansScheme = urlString
    .replacingOccurrences(of: "https://", with: "")
    .replacingOccurrences(of: "http://", with: "")

// Good: Substring slicing, zero allocations
let urlSansScheme: Substring
if urlString.hasPrefix("https://") {
    urlSansScheme = urlString[urlString.index(urlString.startIndex, offsetBy: 8)...]
} else if urlString.hasPrefix("http://") {
    urlSansScheme = urlString[urlString.index(urlString.startIndex, offsetBy: 7)...]
} else {
    urlSansScheme = Substring(urlString)
}
```

**Measured win:** 4,370 → 1,011 mallocs per keystroke (77% reduction) on the OmniboxSuggester path.

### ✅ Know the small-string optimisation

Strings ≤ 15 UTF-8 bytes on 64-bit arm64 are stored inline (no heap allocation). Keeping hot keys (URL schemes, hostnames, short queries) under this threshold is a real optimisation.

---

## Collections — Bounded Top-N Beats Full Sort

### ✅ Partial sort with insertion barrier

```swift
// Bad: sort all 500, keep 6
return best.values
    .sorted { $0.score > $1.score }
    .prefix(limit)

// Good: bounded insertion (keep at most `limit` entries)
var best: [(score: Double, entry: HistoryEntry)] = []
best.reserveCapacity(limit + 1)

for entry in history {
    // ... compute score ...
    let insertIndex = best.firstIndex { $0.score < score } ?? best.endIndex
    best.insert((score, entry), at: insertIndex)
    if best.count > limit {
        best.removeLast()
    }
}
```

**Why:** Sorting 500 entries when you display 6 is O(n log n). Bounded insertion is O(n × limit) = O(n). With `limit = 6`, this is ~10× fewer comparisons.

### ✅ `reserveCapacity` on known-size collections

```swift
var seenURLs: Set<String> = []
seenURLs.reserveCapacity(limit)  // avoid resizing as we insert
```

---

## SQLite — Prepared Statement Cache

### ✅ Cache `sqlite3_prepare_v2` results

```swift
private var statementCache: [String: OpaquePointer] = [:]

private func cachedStatement(_ sql: String) throws -> OpaquePointer {
    if let cached = statementCache[sql] {
        sqlite3_reset(cached)
        sqlite3_clear_bindings(cached)
        return cached
    }
    // ... prepare and cache ...
}
```

**Why:** `sqlite3_prepare_v2` parses and validates SQL. On a hot path (HistoryStore query every keystroke), this overhead adds up. After caching, the first call prepares, subsequent calls reset + rebind only.

### ✅ Index what you query

```sql
-- The query that runs on every keystroke:
SELECT ... FROM history
WHERE url LIKE ?1 OR title LIKE ?1
ORDER BY visit_count DESC, last_visit DESC LIMIT ?2;

-- Indexes that help:
CREATE INDEX idx_history_url ON history(url);           -- prefix matching
CREATE INDEX idx_history_score ON history(visit_count DESC, last_visit DESC);  -- ORDER BY
```

**Note:** `LIKE %query%` (leading wildcard) cannot use a B-tree index. For substring searches, consider FTS5 or accept the full table scan. Prefix matching (`LIKE 'query%'`) can use the index.

---

## Module Boundaries — `@inlinable` for Hot Functions

### ✅ When to use `@inlinable`

```swift
public enum OmniboxSuggester {
    @inlinable
    public static func suggestions(...) { ... }

    @usableFromInline
    static func matchScore(...) -> Double? { ... }
}
```

**Rules:**
- `@inlinable` exposes the function body to the module's binary interface. Changing it requires recompiling all consumers.
- Every private function/variable referenced by the `@inlinable` body must be `@usableFromInline` or `public`.
- Best used on tiny, stable functions on the hot path that are unlikely to change.
- **Measured win may be invisible to `mallocCountTotal`** — `@inlinable` affects specialization and ARC traffic, not allocation counts. Use wall-clock or Instruments Time Profiler to measure.

---

## ARC and Ownership

### ✅ `final` on non-subclassed classes

```swift
public final class HistoryStore { ... }  // enables static dispatch
```

Swift cannot devirtualise calls to non-final classes. Marking classes `final` (where appropriate) enables the compiler to skip the vtable lookup.

### ✅ `reserveCapacity` on arrays in tight loops

```swift
var best: [(score: Double, entry: HistoryEntry)] = []
best.reserveCapacity(limit + 1)  // one allocation, not N
```

---

## Benchmarking — Measure What Matters

### ✅ `mallocCountTotal` is deterministic, wall-clock is not

```swift
let checkedMetrics: [BenchmarkMetric] = [.mallocCountTotal]
let tolerance: [BenchmarkMetric: BenchmarkThresholds] = [
    .mallocCountTotal: .init(relative: [.p90: 25.0])
]
```

**Why:** Allocation counts are near-deterministic for a given code path. Wall-clock varies with machine load, thermal throttling, and ASLR. CI on shared runners makes wall-clock useless.

### ✅ jemalloc requirement

`package-benchmark`'s `mallocCountTotal` metric requires jemalloc. Install with `brew install jemalloc` and set:

```bash
export PKG_CONFIG_PATH="$(brew --prefix jemalloc)/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
```

---

## Concurrency (Swift 5.10, targeted)

### ✅ Single coalesced timer

```swift
// One timer for the whole app, not per-tab
let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(10))
```

**Why:** Per-tab timers multiply wakeups. One timer with generous leeway (10s) lets the system coalesce our wakeup with others.

### ✅ `@MainActor` on app-layer classes

```swift
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate { ... }
```

Pure models (like `EnergyGovernor`) are `Sendable` where possible. The app layer owns the MainActor boundary.

---

## Apple Silicon Specific

- **arm64 has a weaker memory model** than x86_64. Code that works on Intel through stronger implicit ordering can fail here. Prefer `Mutex` from `Synchronization` over hand-rolled atomics.
- **QoS matters:** background work (blocklist compile, history queries) should land on efficiency cores. Verify the QoS used by `WKContentRuleListStore` compilation.
- **Unified memory:** GPU and CPU pressure are the same pressure. WebKit content processes compete with everything Qwave allocates.