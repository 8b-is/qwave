---
title: "Zero-Allocation Text Handling on the Keystroke Path"
status: draft
date: 2026-08-13
updated: 2026-08-13
site: pocoo.vaked.dev
tags: [swift, performance, string, allocation, macos, sqlite, profiling]
repo: https://github.com/8b-is/qwave
commit: 15c1389aa0e2ccff5bf80cb85b62d7dcc6a2b6a9
measured_on: "Apple M1 Max (8 P-cores / 2 E-cores), 64 GB unified memory, macOS 26.4, Xcode 16.4. Release build, package-benchmark mallocCountTotal."
---

# Zero-allocation text handling on the keystroke path

*Long-form engineering post. Everything below is measured, linked to the exact
commit and line ranges, and carries a permanent draft status — reserve the
right to be wrong until publication.*

There is one code path in Qwave that I am allowed to care about
disproportionately: the omnibox keystroke path. It is the only path that runs
inside the user's perception of typing. If it stutters, the browser — an app
whose entire value proposition is being fast — *feels* slow, no matter how
good its tab hibernation or content shields are.

This is the story of removing 77% of the heap allocations from that path. Not
with unsafe pointers, not with a custom allocator, not with assembly. Mostly
by *stopping doing pointless work*: sorting 500 elements to keep 6, and
rewriting a two-per-entry string rewrite that needn't have existed at all.

## Why the keystroke path is special

A fast typist emits roughly 5–10 characters per second; a very fast burst
reaches one character every ~70 ms. Every one of those key presses fires
`controlTextDidChange` on the `NSTextField`, and from that moment we are on
budget. The rough human-perception rule of thumb is that anything under
~100 ms feels instantaneous, which sounds generous — until you remember the
chain runs synchronously, on the main thread, and includes a WHATWG URL
parse and a SQLite query. And when there *is* a hitch, every subsequent
keystroke in the burst queues behind it, so the user doesn't experience one
80 ms stall, they experience four 20 ms stalls — the worst kind.

As of Qwave v0.3.0 ([commit `b940468`](https://github.com/8b-is/qwave/commit/b940468),
the omnibox UX landing), the chain looks like this:

![Per-keystroke pipeline: key press → OmniboxParser.parse → HistoryStore query → OmniboxSuggester.suggestions → dropdown, with before/after malloc counts](assets/omnibox-keystroke-path.svg)

1. **[`OmniboxParser.parse`](https://github.com/8b-is/qwave/blob/15c1389aa0e2ccff5bf80cb85b62d7dcc6a2b6a9/Packages/QwaveKit/Sources/BrowserCore/OmniboxParser.swift#L11-L81)**
   — decides *URL vs search query* using the WHATWG parser via
   [WebURL](https://github.com/karwa/swift-url), so the host identity we
   compute is the identity WebKit will actually load.
2. **[`HistoryStore.entries(matching:)`](https://github.com/8b-is/qwave/blob/15c1389aa0e2ccff5bf80cb85b62d7dcc6a2b6a9/Packages/QwaveKit/Sources/Persistence/HistoryStore.swift#L86-L121)**
   — a `LIKE '%query%'` search over up to 50k history rows.
3. **[`OmniboxSuggester.suggestions`](https://github.com/8b-is/qwave/blob/15c1389aa0e2ccff5bf80cb85b62d7dcc6a2b6a9/Packages/QwaveKit/Sources/BrowserCore/OmniboxSuggester.swift#L26-L63)**
   — scores every matching row and returns the top 6 for the dropdown.
4. The dropdown UI renders those six rows.

Step 4 is AppKit's problem. Steps 1–3 are mine.

## The metric: counting allocations, not milliseconds

Before touching anything, a word on *what* I measured, because it shapes the
whole post. The number under optimization is `mallocCountTotal` from
[ordo-one/package-benchmark](https://github.com/ordo-one/package-benchmark) —
the raw count of `malloc` calls per benchmark iteration — not wall-clock time.

The rationale deserves its own post and has one:
[why-we-benchmark-allocations-not-wall-clock.md](why-we-benchmark-allocations-not-wall-clock.md).
The short version: allocation counts are *deterministic for a given code
path*. Two runs of the same code allocate the same things regardless of what
else the machine is doing, which means benchmarks survive noisy CI runners,
heterogeneous hardware, and thermal states. Wall-clock survives none of
those, so it is collected but never CI-gated; `mallocCountTotal` is gated in
CI with a 25% p90 tolerance
([`QwaveKitBenchmarks.swift#L15-L24`](https://github.com/8b-is/qwave/blob/15c1389aa0e2ccff5bf80cb85b62d7dcc6a2b6a9/Benchmarks/Benchmarks/QwaveKitBenchmarks/QwaveKitBenchmarks.swift#L15-L24),
suite originally introduced in
[commit `f3402ea`](https://github.com/8b-is/qwave/commit/f3402ea)).

Allocations are also a good *proxy* for CPU here: each `malloc` implies lock
acquisition in the allocator, size-class bookkeeping, and eventually
`free` — on the main thread, at keystroke cadence. Kill allocations and the
milliseconds generally follow.

## The before numbers

Measured with the in-process benchmark suite, release build, on the M1 Max
noted in the frontmatter:

| Sub-path | mallocs/iteration | Why it's hot |
|---|---|---|
| `OmniboxParser.parse` (3 cases) | 30 | WebURL parser, `String` operations |
| `OmniboxSuggester.suggestions` (500 entries) | **4,370** | Full sort, `replacingOccurrences`, multiple `lowercased()` |
| `HistoryStore.entries(matching:)` (50k rows) | 402–628 | `sqlite3_prepare_v2` every call, no index |

The benchmarks are real code, readable here:
[parse benchmark `L29-L38`](https://github.com/8b-is/qwave/blob/15c1389aa0e2ccff5bf80cb85b62d7dcc6a2b6a9/Benchmarks/Benchmarks/QwaveKitBenchmarks/QwaveKitBenchmarks.swift#L29-L38) ·
[suggester benchmark with the synthetic 500-row history `L41-L60`](https://github.com/8b-is/qwave/blob/15c1389aa0e2ccff5bf80cb85b62d7dcc6a2b6a9/Benchmarks/Benchmarks/QwaveKitBenchmarks/QwaveKitBenchmarks.swift#L41-L60) ·
[history benchmark opening against a real on-disk 50k-row SQLite database `L63-L70`](https://github.com/8b-is/qwave/blob/15c1389aa0e2ccff5bf80cb85b62d7dcc6a2b6a9/Benchmarks/Benchmarks/QwaveKitBenchmarks/QwaveKitBenchmarks.swift#L63-L70).

The suggester at 4,370 was the obvious target: eight to nine allocations *per
history row*, per keystroke. The parser's 30 was already honest. The history
query had a different problem — its allocation cost was incidental next to
what `sqlite3_prepare_v2` was doing to its latency.

## Change 1: the sort was the allocation

This is where most of the win came from, and it is embarrassing how
mechanical it was. The original code
([before, parent commit `5fe2b0a`, `L32-L51`](https://github.com/8b-is/qwave/blob/5fe2b0a5f9edaf0ca853bc7e7481b77fe22b702e/Packages/QwaveKit/Sources/BrowserCore/OmniboxSuggester.swift#L32-L51))
accumulated every match into a `Dictionary` keyed by URL, then sorted the
whole thing to keep the six best:

```swift
// BEFORE (commit 5fe2b0a) — accumulate everything, sort everything, keep 6
var best: [String: (score: Double, entry: HistoryEntry)] = [:]
for entry in history {
    guard let base = matchScore(trimmed, entry: entry) else { continue }
    // ... frequency + recency scoring ...
    let key = entry.url.absoluteString
    if let existing = best[key], existing.score >= score { continue }
    best[key] = (score, entry)
}

return best.values
    .sorted { lhs, rhs in
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return lhs.entry.lastVisit > rhs.entry.lastVisit
    }
    .prefix(limit)
    .map { OmniboxSuggestion(url: $0.entry.url, title: $0.entry.title) }
```

Consider what this does to keep **6** results:

* A `Dictionary` grows from empty to 500 entries — hash allocation and
  several rehash-copy cycles along the way.
* `.sorted(> )` allocates a sort buffer for ~500 tuples and performs
  O(n log n) comparisons, each comparing doubles and, on ties, `Date`s.
* Then `prefix(limit)` throws 494 of them away.

I sorted five hundred things to drop four hundred ninety-four of them. The
sort isn't *technically* wrong; it's just thinking in "sort order" when the
requirement is "top-k".

![Illustration: full-sort-then-prefix-6 versus a bounded top-6 insertion buffer](assets/bounded-insertion-sort.svg)

The replacement is a bounded insertion sort
([after, `L37-L63`](https://github.com/8b-is/qwave/blob/15c1389aa0e2ccff5bf80cb85b62d7dcc6a2b6a9/Packages/QwaveKit/Sources/BrowserCore/OmniboxSuggester.swift#L37-L63)),
verbatim from the repo:

```swift
// Bounded insertion sort with URL deduplication — only keep the
// top `limit` entries instead of sorting the full set.
var best: [(score: Double, entry: HistoryEntry)] = []
best.reserveCapacity(limit + 1)
var seenURLs: Set<String> = []
seenURLs.reserveCapacity(limit)

for entry in history {
    guard let base = matchScore(trimmed, entry: entry) else { continue }
    let frequency = 5.0 * log2(Double(entry.visitCount) + 1)
    let age = now.timeIntervalSince(entry.lastVisit)
    let recency: Double = age < 7 * 86_400 ? 10 : (age < 30 * 86_400 ? 5 : 0)
    let score = base + frequency + recency

    let key = entry.url.absoluteString
    guard seenURLs.insert(key).inserted else { continue }

    // Insert in sorted position, capped at `limit`.
    let insertIndex = best.firstIndex { $0.score < score } ?? best.endIndex
    best.insert((score, entry), at: insertIndex)
    if best.count > limit {
        best.removeLast()
    }
}

return best.map { OmniboxSuggestion(url: $0.entry.url, title: $0.entry.title) }
```

The buffer is `reserveCapacity(limit + 1)` = 7 tuples, allocated once,
forever, regardless of history size. Insertion is `firstIndex` over at most
6 elements plus a memmove. The worst case is O(n·k) instead of O(n log n),
and with k = 6 that is a housekeeping cost, not a sort. The dedup `Set` is
also pre-sized so it starts at capacity instead of growing.

A note on honesty: the O(n) scan over all 500 rows remains. It was never the
problem. The problem was everything we did *after* scoring each row.

## Change 2: deleting strings that never needed to exist

Every matching row went through `matchScore`, and `matchScore` started by
manufacturing strings:

```swift
// BEFORE (commit 5fe2b0a) — per entry, per keystroke:
let hostSansWWW = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
let urlSansScheme =
    urlString
    .replacingOccurrences(of: "https://", with: "")
    .replacingOccurrences(of: "http://", with: "")
```

([before, `L54-L71`](https://github.com/8b-is/qwave/blob/5fe2b0a5f9edaf0ca853bc7e7481b77fe22b702e/Packages/QwaveKit/Sources/BrowserCore/OmniboxSuggester.swift#L54-L71))

`replacingOccurrences` is the classic Foundation convenience trap. It scans
the entire string for a *pattern* (using `NSString` semantics, no less) when
the question is actually "does it start with this, and if so, drop 8
characters". Two chained calls means a full intermediate `String`
allocation, thrown away immediately, on the majority of rows (most URLs in
history are `https://`, so the second call is a wasted no-op scan and the
first produced a temporary).

The fix is to answer the question that was actually being asked
([after, `L65-L88`](https://github.com/8b-is/qwave/blob/15c1389aa0e2ccff5bf80cb85b62d7dcc6a2b6a9/Packages/QwaveKit/Sources/BrowserCore/OmniboxSuggester.swift#L65-L88)):

```swift
// AFTER — Substring slices share storage with the String they came from.
let host = (entry.url.host ?? "").lowercased()
let hostSansWWW = host.hasPrefix("www.")
    ? host[host.index(host.startIndex, offsetBy: 4)...]
    : Substring(host)
let urlString = entry.url.absoluteString.lowercased()
// Strip scheme via prefix drop instead of replacingOccurrences.
let urlSansScheme: Substring
if urlString.hasPrefix("https://") {
    urlSansScheme = urlString[urlString.index(urlString.startIndex, offsetBy: 8)...]
} else if urlString.hasPrefix("http://") {
    urlSansScheme = urlString[urlString.index(urlString.startIndex, offsetBy: 7)...]
} else {
    urlSansScheme = Substring(urlString)
}
```

A `Substring` is two pointers into the *existing* string's storage; creating
one is a stack operation. The trade-off people warn about — a `Substring`
pinning a huge backing buffer — doesn't apply here because the lifetime is
three lines: slice, compare, drop.

The other half of the trap is invisible unless you know to look: Swift's
*small-string optimization* keeps `String`s of ≤15 bytes inline with no heap
allocation at all. `"github.com"` is 10 bytes. So is `"qwave"` or most
hosts. `lowercased()` on such strings was *already* free — which is part of
why the remaining, legitimate `lowercased()` calls (one per field per entry)
were left alone: the ones that matter fit on the stack, and the ones that
don't are the URL/title, where a single lowercased copy is genuinely needed
for case-insensitive `hasPrefix`/`contains`. Hence 1,011 remaining
allocations, not zero. The headline of this post is the surviving few:
the *removal* is bounded by what the domain actually needs.

## Change 3: `sqlite3_prepare_v2` once, not per keystroke

The history query's 402–628 allocations weren't even its worst sin.
Every keystroke ran the full SQLite statement lifecycle: parse the SQL text,
validate the schema, build a query plan, run, then `sqlite3_finalize` the
result. Per keystroke. For the same two SQL strings, forever.

The fix is the oldest trick in the SQLite book — cache prepared statements —
implemented in the persistence layer where it belongs
([after, `SQLiteDatabase.swift`](https://github.com/8b-is/qwave/blob/15c1389aa0e2ccff5bf80cb85b62d7dcc6a2b6a9/Packages/QwaveKit/Sources/Persistence/SQLiteDatabase.swift)):

```swift
/// Caches prepared statements keyed by SQL text so the hottest queries
/// (HistoryStore on every keystroke) skip sqlite3_prepare_v2 overhead.
/// Guarded by queue.sync — all database access is serialized.
private var statementCache: [String: OpaquePointer] = [:]
```
— [field declaration, `L55-L58`](https://github.com/8b-is/qwave/blob/15c1389aa0e2ccff5bf80cb85b62d7dcc6a2b6a9/Packages/QwaveKit/Sources/Persistence/SQLiteDatabase.swift#L55-L58)

```swift
/// Returns a cached prepared statement for `sql`, or prepares and caches one.
private func cachedStatement(_ sql: String) throws -> OpaquePointer {
    guard let handle else { throw SQLiteError.prepareFailed(code: -1, message: "no database", sql: sql) }
    if let cached = statementCache[sql] {
        sqlite3_reset(cached)
        sqlite3_clear_bindings(cached)
        return cached
    }
    var stmt: OpaquePointer?
    let code = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
    guard code == SQLITE_OK, let stmt else { ... }
    statementCache[sql] = stmt
    return stmt
}
```
— [cache hit = reset + rebind only, `L101-L115`](https://github.com/8b-is/qwave/blob/15c1389aa0e2ccff5bf80cb85b62d7dcc6a2b6a9/Packages/QwaveKit/Sources/Persistence/SQLiteDatabase.swift#L101-L115)

A statement on the hot path is now `reset` + `clear_bindings` + rebind +
step. The cache is keyed by SQL *text* (there are only ever a handful of
distinct queries — Qwave's persistence layer is deliberately dependency-free
and the SQL surface is small, so an unbounded-by-text cache is fine). The
corresponding `sqlite3_finalize` on each cached statement happens once, in
[`deinit`, `L87-L94`](https://github.com/8b-is/qwave/blob/15c1389aa0e2ccff5bf80cb85b62d7dcc6a2b6a9/Packages/QwaveKit/Sources/Persistence/SQLiteDatabase.swift#L87-L94).
Every `query(_:_:_:)` call routes through it
([`L133-L142`](https://github.com/8b-is/qwave/blob/15c1389aa0e2ccff5bf80cb85b62d7dcc6a2b6a9/Packages/QwaveKit/Sources/Persistence/SQLiteDatabase.swift#L133-L142)),
so no call site needed to change. That last property — *no caller changed* —
is what made this a five-minute review instead of a five-day one.

## Change 4: the indexes that were missing

While in there, two indexes went in
([`HistoryStore.swift`, `L42-L44`](https://github.com/8b-is/qwave/blob/15c1389aa0e2ccff5bf80cb85b62d7dcc6a2b6a9/Packages/QwaveKit/Sources/Persistence/HistoryStore.swift#L42-L44)):

```swift
CREATE INDEX IF NOT EXISTS idx_history_last_visit ON history(last_visit DESC);
CREATE INDEX IF NOT EXISTS idx_history_url ON history(url);
CREATE INDEX IF NOT EXISTS idx_history_score ON history(visit_count DESC, last_visit DESC);
```

`idx_history_url` helps point lookups and joins on `url`; the composite
`idx_history_score(visit_count DESC, last_visit DESC)` exists because the
suggester's SQL
([`L100-L109`](https://github.com/8b-is/qwave/blob/15c1389aa0e2ccff5bf80cb85b62d7dcc6a2b6a9/Packages/QwaveKit/Sources/Persistence/HistoryStore.swift#L86-L121))
ends in `ORDER BY visit_count DESC, last_visit DESC` — a compound sort the
engine can now satisfy from the index instead of building a temp B-tree.

One honest caveat: `WHERE url LIKE ?1 OR title LIKE ?1` with a *leading*
wildcard (`%' + query + '%'`) still can't use a B-tree index on the filter
side. The indexes helped the `ORDER BY`, not the `WHERE`. Making the filter
indexable is the FTS5 thread listed under *what I left on the table* below.

## Results

![Bar chart: suggester allocations per iteration fall from 4,370 to 1,011, a 77% reduction](assets/omnibox-mallocs-before-after.svg)

| Metric | Before | After | Δ |
|---|---|---|---|
| OmniboxSuggester (500 entries) | 4,370 mallocs | **1,011 mallocs** | **−77%** |
| HistoryStore query (50k rows) | 402–628 mallocs | **391 mallocs** | −3% to −38% |
| OmniboxParser.parse | 30 mallocs | 30 mallocs | — |

The 77% reduction in the suggester is the headline: **3,359 fewer heap
allocations per keystroke**, and the whole per-keystroke chain lands at
roughly 1,430 mallocs app-side, down from ~4,800–5,030 (visualized in the
pipeline diagram at the top; total −70%).

The history row deserves a beat of context: 391 vs 402–628 is a modest
*allocation* win because SQLite rows materialize and the `CompactMap`/`URL`
construction in the row transform still allocates. The point of the
statement cache was always prepare-time *latency and lock traffic*, which
`mallocCountTotal` doesn't measure. Methodological honesty: this post's
metric understates the SQLite win.

The same commit also converted `OmniboxParser`'s heuristics from
`split(separator:)` (which materializes an `Array<Substring>`) to
`firstIndex(of:)` + slicing
([`OmniboxParser.swift`, `L38-L48`](https://github.com/8b-is/qwave/blob/15c1389aa0e2ccff5bf80cb85b62d7dcc6a2b6a9/Packages/QwaveKit/Sources/BrowserCore/OmniboxParser.swift#L38-L48)),
but the parser was aggregate-benchmarked across three very different cases
and sat at 30 both before and after — within run-to-run noise of the
three-case aggregate. Birthday reminder that removal of an allocation of the
*kind* (Array of Substrings) matters on the real string lengths involved,
not on the benchmark strings chosen.

## What didn't work

Three dead ends, all worth one line each because other people will have the
same ideas:

* **UTF8View everywhere.** Tried operating on `String.UTF8View` for
  scoring. Swift's `String` APIs are genuinely well-optimized; the win went
  from "removing intermediate strings" to "making the comparisons harder",
  with more complexity and no measurable allocation or time improvement.
* **FTS5 for history search.** Would make `WHERE title LIKE` indexable and
  kill the full-scan — but adds a toolchain dependency (or a module-map
  dance), a schema migration, and ongoing maintenance. Deferred, not
  dismissed.(See *left on the table* below.)
* **`@inlinable` as an optimization.** The same commit also added
  `@inlinable`/`@usableFromInline` on hot cross-module functions
  ([`OmniboxSuggester`](https://github.com/8b-is/qwave/blob/15c1389aa0e2ccff5bf80cb85b62d7dcc6a2b6a9/Packages/QwaveKit/Sources/BrowserCore/OmniboxSuggester.swift#L27),
  [`OmniboxParser`](https://github.com/8b-is/qwave/blob/15c1389aa0e2ccff5bf80cb85b62d7dcc6a2b6a9/Packages/QwaveKit/Sources/BrowserCore/OmniboxParser.swift#L12)).
  Measured effect on `mallocCountTotal`: **zero, exactly** — the metric
  counts allocations, not instructions, and allocations don't vanish when
  call sites inline. The null result got its own post:
  [measured-cost-of-a-swift-module-boundary.md](measured-cost-of-a-swift-module-boundary.md).
  The annotations stayed because they cost nothing, but they're removal of a
  thing (module-boundary dispatch) rather than an in-place optimization.

## What I left on the table

* The `LIKE '%query%'` full-table scan remains; FTS5 is the answer and I've
  deferred it.
* The chain still runs synchronously per keystroke. Event coalescing
  (grouping rapid keystrokes into one scoring pass, the address-bar
  equivalent of debouncing) is a larger architectural change and deserves
  its own piece of work.
* Matching 50k+ rows means the `LIKE` scan dominates the ranking phase at
  real-world scale; the bounded top-6 keeps the *output* cost constant but
  the *input* scan is what will eventually force FTS5's hand.

## Reproduce it

The whole thing is checkable from cursor to CI gate:

```bash
git clone https://github.com/8b-is/qwave.git && cd qwave/Benchmarks
swift package benchmark run                              # full local measurement
swift package benchmark thresholds check --no-progress   # what CI asserts
```

Commit [`15c1389`](https://github.com/8b-is/qwave/commit/15c1389aa0e2ccff5bf80cb85b62d7dcc6a2b6a9)
is the single point where everything above landed; its parent
[`5fe2b0a`](https://github.com/8b-is/qwave/commit/5fe2b0a5f9edaf0ca853bc7e7481b77fe22b702e)
is the "before" you can check out to reproduce the regression yourself (`git
checkout 5fe2b0a` and re-run the same benchmarks).

## Key takeaways

1. **Data-structure choice dominates micro-tricks.** The entire aim of the
   suggester change was "stop being a sort, start being a top-k." That one
   conceptual move, plus `reserveCapacity`, did more than a week of
   pointer-counting could have.
2. **Claim the primitives people reach for as opportunities.**
   `replacingOccurrences` and `sorted()` are the two most common "allocating
   convenience" APIs on a text path in Swift. Audit them first.
3. **`Substring` is the default slice semantics you want on a hot path:**
   zero-copy, bounded lifetime, keeps the domain-model strings untouched.
4. **Prepare once.** Whatever database you're on, re-preparing identical SQL
   is tax paid concurrently with the user's perception of their own typing.
5. **Check for missing indexes before micro-optimizing queries.**
6. **Null results are results.** `@inlinable`, UTF8 views, pointer tricks —
   measure them; if they don't move the number, get their cost out of the
   code.

*Benchmarks, CSVs and CI thresholds:
[Benchmarks/](https://github.com/8b-is/qwave/tree/15c1389aa0e2ccff5bf80cb85b62d7dcc6a2b6a9/Benchmarks).
Sister posts in this series:
[why we count allocations not wall clock](why-we-benchmark-allocations-not-wall-clock.md) ·
[the measured cost of a module boundary](measured-cost-of-a-swift-module-boundary.md) ·
[measuring memory a browser doesn't own](measuring-memory-a-browser-doesnt-own.md) ·
[what 59,657 blocking rules cost](what-59657-blocking-rules-cost.md).*
