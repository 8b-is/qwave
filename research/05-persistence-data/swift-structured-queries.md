# swift-structured-queries (`pointfreeco/swift-structured-queries`)

| | |
|---|---|
| **Repo** | https://github.com/pointfreeco/swift-structured-queries |
| **Version** | **0.36.0** (Aug 11) |
| **License** | MIT |
| **Platforms** | macOS, iOS, tvOS, watchOS, Linux |
| **Apple Silicon** | Pure Swift + macros |
| **Verified** | 2026-08-12 |

---

## What it is

A type-safe SQL query builder driven by Swift macros. It generates SQL at compile time from
Swift expressions, so column names, types, and joins are checked by the compiler rather than
discovered at runtime when a query returns nothing.

It is the query layer beneath [SQLiteData](sqlite-data.md), and it is usable standalone. The
0.36.0 release added `jsonArrayInsert`, typed-throws query decoding, better macro diagnostics,
and SQLite compatibility fixes — an active, still pre-1.0 project.

## Why it matters for Qwave

The specific failure it prevents is one every hand-rolled SQLite layer eventually hits:

```swift
// Today, in Persistence — a typo the compiler cannot see
let sql = "SELECT url, title, visted_at FROM history ORDER BY visited_at DESC LIMIT ?"
//                          ^^^^^^^^^ ships fine, fails at runtime

// With structured queries — this does not compile
let query = HistoryEntry
    .order(by: \.visitedAt, .descending)
    .limit(200)
```

Qwave's `Persistence` module is raw SQL strings across four stores. Column renames, added
indexes, and schema evolution are all silent-failure opportunities. `HistoryStoreTests`,
`BookmarkStoreTests`, and `SessionStoreTests` catch a lot of this — but tests catch the queries
you thought to test, and the compiler catches all of them.

The `jsonArrayInsert` addition in 0.36.0 is incidentally relevant: `SessionStore` persists tab
session state, which is naturally document-shaped. SQLite's JSON functions are the right tool
there, and having them typed is a genuine improvement over string-built JSON SQL.

## Apple Silicon notes

No runtime architecture concerns — the macro work happens at compile time and the output is
ordinary SQL against the system SQLite.

The compile-time cost is the real consideration. Macro-heavy packages meaningfully lengthen clean
builds, which matters for CI. Swift 6.2's prebuilt swift-syntax support directly addresses this
(see [PLATFORM-BASELINE.md](../PLATFORM-BASELINE.md)) and is a prerequisite worth having in place
first.

## Adoption sketch

Standalone use, on top of [GRDB](grdb.md):

```swift
.package(url: "https://github.com/pointfreeco/swift-structured-queries", from: "0.36.0")
```

```swift
@Table
struct HistoryEntry {
    let id: UUID
    var url: String
    var host: String
    var title: String
    var visitedAt: Date
}

// Compile-checked, composable
let recent = HistoryEntry
    .where { $0.host == host }
    .order(by: \.visitedAt, .descending)
    .limit(50)
```

## Risks

- **Pre-1.0 (0.36.x) with active feature work.** Breaking changes between minors are expected at
  this stage. That is a real cost in the module holding user data.
- **Macro compile-time cost**, on a project whose CI builds a full macOS app.
- **Third dependency in the persistence stack** if combined with GRDB and SQLiteData.
- **Learning curve.** The macro DSL is expressive and idiomatic once learned, and opaque before
  that. Diagnostics improved in 0.36.0, which tells you where they were.

## Verdict

🟡 **Assess — the right idea, at the wrong version, for this module.**

Compile-time-checked SQL is a genuine improvement over string queries, and the specific bug class
it eliminates is one Qwave is currently exposed to across four stores.

But `Persistence` is the module where breakage means lost user history, and a pre-1.0 dependency
with active API churn is a poor match for that risk profile. [GRDB](grdb.md)'s own query
interface already provides substantial type safety at 7.x maturity, which is the better
risk-adjusted trade today.

**Revisit at 1.0**, or sooner if GRDB's query interface proves insufficient in practice.
