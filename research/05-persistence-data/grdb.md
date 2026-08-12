# GRDB (`groue/GRDB.swift`)

| | |
|---|---|
| **Repo** | https://github.com/groue/GRDB.swift |
| **Version** | **7.11.1** (Jun 18) |
| **License** | MIT |
| **Platforms** | macOS, iOS, tvOS, watchOS, visionOS, Linux |
| **Apple Silicon** | Wraps the system SQLite; arm64-native |
| **Verified** | 2026-08-12 |

---

## What it is

The Swift toolkit for SQLite — the most battle-tested database library on Apple platforms, and
the foundation under both [SQLiteData](sqlite-data.md) and Point-Free's Sharing-GRDB.

GRDB does not hide SQL. You write queries; GRDB handles everything around them: connection
management, concurrency, migrations, decoding, and change observation. The 7.11.1 release is
representative of its maintenance quality — making migration registration O(1) in DEBUG builds.

## Why it matters for Qwave

`Persistence/SQLiteDatabase.swift` is a hand-rolled wrapper over the SQLite C API in WAL mode.
GRDB is the same idea, done comprehensively, with a decade of production hardening.

### `ValueObservation` — the decisive feature

`QwaveApp/LibraryWindow.swift` displays history and bookmarks. Those tables are written by
`NavigationCoordinator` on every page load, from a different part of the app. Keeping the view
current is either a manual refresh (stale UI) or a hand-rolled notification layer (a bug farm).

```swift
// The Library window stays live with no notification plumbing at all
let observation = ValueObservation.tracking { db in
    try HistoryEntry
        .order(Column("visitedAt").desc)
        .limit(200)
        .fetchAll(db)
}

for try await entries in observation.values(in: dbPool) {
    await MainActor.run { self.entries = entries }
}
```

GRDB observes at the SQLite level, so it sees every write regardless of which module made it.

### `DatabasePool` — correct WAL concurrency

Qwave already uses WAL mode, whose entire point is concurrent readers alongside one writer.
Realising that safely means managing separate reader and writer connections with correct
lifetimes. `DatabasePool` is exactly that, done right — and it is the piece most likely to be
subtly wrong in a hand-rolled implementation, because the failure mode is not a crash but rare
`SQLITE_BUSY` errors under load.

### `DatabaseMigrator` — versioned schema

`SessionStore` restores browser sessions across launches. When that schema changes, existing
users' data must migrate or their tabs are gone. Hand-rolled migrations tend to work until the
second one.

```swift
var migrator = DatabaseMigrator()
migrator.registerMigration("v1_history") { db in
    try db.create(table: "history") { t in
        t.primaryKey("id", .text)
        t.column("url", .text).notNull().indexed()
        t.column("host", .text).notNull().indexed()   // pairs with WebURL canonical hosts
        t.column("visitedAt", .datetime).notNull()
    }
}
try migrator.migrate(dbPool)
```

## Apple Silicon notes

GRDB wraps the system SQLite, which is arm64-native and Apple-tuned. Two Apple Silicon-relevant
points:

- **Unified memory makes the page cache cheap.** SQLite's cache competes with WebKit content
  processes for the same pool, so `DatabasePool`'s bounded connection count is a memory-footprint
  feature, not just a correctness one — directly relevant to `TabHibernator`'s purpose.
- **Efficiency cores handle database I/O well.** Reads dispatched off the main actor land on
  E-cores under normal QoS, which is exactly right for history queries feeding a Library window.

## Adoption sketch

```swift
// Packages/QwaveKit/Package.swift
.package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
// on the Persistence target:
.product(name: "GRDB", package: "GRDB.swift")
```

Migrate one store at a time behind the existing protocol boundaries. `HistoryStore` first: most
rows, most churn, and `HistoryStoreTests` already covers the behaviour.

The public API of `Persistence` should not change — `BrowserCore` and `QwaveApp` continue to see
`HistoryStore`, not GRDB types. That keeps the dependency contained and the migration reversible.

## Risks

- **First runtime dependency in `Persistence`.** For a sovereign browser, every dependency in the
  path of user data deserves scrutiny. GRDB is MIT, single-maintainer but exceptionally
  well-maintained, widely audited, and has no network surface — about as safe as this gets.
- **Migration is real work.** Four stores plus `SQLiteDatabase`. Incremental and test-covered,
  but not a weekend.
- **API surface is large.** Easy to over-adopt. Keep GRDB types out of `BrowserCore` entirely.
- **Existing data must be preserved.** Users upgrading from 0.1.0 have real history and
  bookmarks. Register the current schema as migration `v1` and verify against a real 0.1.0
  database file before shipping.

## Verdict

🟢 **Adopt.**

`Persistence` is the module where hand-rolled code has the worst failure mode: silent data
corruption or lost user history. GRDB replaces the riskiest hand-written code in Qwave with a
decade-hardened library, and `ValueObservation` solves a live-UI problem the current architecture
has no good answer to.

**Start with:** `HistoryStore`, using `HistoryStoreTests` as the contract. Prove the migration
against a real 0.1.0 database before touching the other three stores.
