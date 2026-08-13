---
title: "Zero-allocation text handling on the keystroke path"
status: draft
date: 2026-08-13
tags: [swift, performance, string, allocation, macos]
measured_on: "Apple M1 Max (8 P-cores / 2 E-cores), 64 GB unified memory, macOS 26.4, Xcode 16.4. Release build, package-benchmark mallocCountTotal."
---

## The problem

Qwave's omnibox runs a full URL parse + history suggestion ranking on every keystroke. With v0.3.0, the parse was upgraded to use the WHATWG parser (WebURL) for correct host identity, and history-ranked suggestions were stacked on top. The whole chain now runs on every character typed.

## What we measured (before)

Using `package-benchmark` with `mallocCountTotal`:

| Sub-path | mallocs/iteration | Why it's hot |
|---|---|---|
| `OmniboxParser.parse` (3 cases) | 30 | WebURL parser, String operations |
| `OmniboxSuggester.suggestions` (500 entries) | **4,370** | Full sort, replacingOccurrences, multiple lowercased |
| `HistoryStore.entries(matching:)` (50k rows) | 402-628 | sqlite3_prepare_v2 every call, no index |

## Changes

### 1. Bounded insertion sort instead of full sort

```swift
// Before: sort all 500, keep 6
best.values.sorted { $0.score > $1.score }.prefix(limit)

// After: bounded insertion, keep at most `limit`
best.reserveCapacity(limit + 1)
for entry in history {
    // compute score, insert in sorted position
    if best.count > limit { best.removeLast() }
}
```

### 2. `replacingOccurrences` → prefix drop with `Substring`

```swift
// Before: two intermediate String allocations per entry
urlString.replacingOccurrences(of: "https://", with: "")
    .replacingOccurrences(of: "http://", with: "")

// After: Substring slicing, zero allocations
if urlString.hasPrefix("https://") {
    urlSansScheme = urlString[urlString.index(...offsetBy: 8)...]
}
```

### 3. Prepared statement cache in SQLiteDatabase

```swift
// Before: sqlite3_prepare_v2 on every keystroke
// After: cached, reset + rebind only
private var statementCache: [String: OpaquePointer] = [:]
```

### 4. Missing indexes on HistoryStore

Added `idx_history_url` and `idx_history_score(visit_count DESC, last_visit DESC)`.

## Results

| Metric | Before | After | Δ |
|---|---|---|---|
| OmniboxSuggester (500 entries) | 4,370 mallocs | **1,011 mallocs** | **−77%** |
| HistoryStore query (50k rows) | 402-628 mallocs | **391 mallocs** | −3% to −38% |
| OmniboxParser.parse | 30 mallocs | 30 mallocs | — |

The 77% reduction in the suggester is the headline win: 3,359 fewer allocations per keystroke.

## What didn't work

- **UTF8View for string operations** — Swift's `String` API is already well-optimised. The UTF8View approach created more complexity than savings. The `small-string-optimisation` (≤15 bytes inline) means most URL components are already allocation-free.
- **FTS5 for history search** — would fix the `LIKE %query%` full table scan, but adds a dependency and migration complexity. Deferred.
- **`@inlinable`** — no measurable impact on `mallocCountTotal`. The metric measures allocation count, not instruction count.

## Key takeaway

The biggest wins came from data-structure changes (bounded heap vs full sort) and eliminating `replacingOccurrences` — not from pointer tricks or unsafe Swift. The SQLite prepared-statement cache was a close second. Always check for missing indexes before micro-optimising queries.