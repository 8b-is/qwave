# 05 · Persistence & Data

| Package | Version | Verdict | Qwave module |
|---------|---------|---------|--------------|
| [GRDB](grdb.md) | 7.11.1 | 🟢 Adopt | `Persistence` (all four stores) |
| [SQLiteData](sqlite-data.md) | 1.10.0 | 🟡 Assess | `Persistence` + SwiftUI panes |
| [swift-structured-queries](swift-structured-queries.md) | 0.36.0 | 🟡 Assess | `Persistence` query layer |

---

## Where Qwave stands

`Packages/QwaveKit/Sources/Persistence/` is **raw SQLite**: `SQLiteDatabase.swift` wrapping the
C API in WAL mode, with `HistoryStore`, `BookmarkStore`, `SessionStore`, and `SettingsStore`
built on top.

That was the right call for v0.1.0. Raw SQLite is fast, dependency-free, and completely
predictable — and for a sovereign browser, "I can read every line of code that touches user
data" has real value.

It also means Qwave hand-maintains: statement preparation and finalisation, parameter binding,
result decoding, migration ordering, connection lifetime across threads, and correct WAL
checkpoint behaviour. Every one of those is a place where a subtle bug means corrupted history
or a leaked file descriptor.

## The trade

| | Raw SQLite (today) | [GRDB](grdb.md) |
|--|-------------------|-----------------|
| Dependencies | None | One, MIT, battle-tested |
| Migrations | Hand-rolled | `DatabaseMigrator`, ordered and tested |
| Concurrency | Your problem | `DatabasePool` with WAL reader/writer separation |
| Observation | Manual | `ValueObservation` — changes push to the UI |
| Decoding | Hand-written per row | `FetchableRecord` / `Codable` |
| Auditability | Total | High — one well-known dependency |

The decisive item is **`ValueObservation`**. Qwave's `LibraryWindow` displays history and
bookmarks. Keeping that view current against a database another part of the app is writing to is
either a manual refresh (stale views) or a hand-rolled notification system (a bug farm). GRDB
solves it properly.

## Recommended sequence

1. **Adopt GRDB** for `Persistence`, migrating one store at a time. `HistoryStore` first — it has
   the most rows, the most churn, and existing tests.
2. **Hold on SQLiteData and swift-structured-queries** for now. Both are excellent and both are
   layers *on top of* GRDB. Adopt the foundation, live with it, and revisit the sugar once the
   base migration has proven itself.

That ordering matters: SQLiteData depends on GRDB, so adopting GRDB first is not a detour — it
is the first step of either path.
