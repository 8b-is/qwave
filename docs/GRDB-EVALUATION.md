# GRDB evaluation for Persistence — declined (measured)

**Date:** 2026-08-13. **Decision: do not adopt GRDB for `HistoryStore`.**
Keep the hand-rolled `SQLiteDatabase` path. This records the measurement and
the reasoning so the decision is reversible on new evidence, not re-litigated
from scratch.

## What was evaluated

A parallel `GRDBHistoryStore` (GRDB 7.11.1) with the identical public API and
schema of the shipped raw-SQLite `HistoryStore`, using idiomatic GRDB — a
`DatabaseQueue`, a `DatabaseMigrator`, and `Row.fetchAll`. It was built, tested
for behavioural parity and data-safety, and benchmarked against the raw path.

## Finding 1 — migration is safe (the good news)

The `history` **table** schema is byte-identical across every shipped version
(v0.3.0 → v0.4.4); the only change was v0.4.4 adding two indexes. So
"migration v1 = the current schema" is correct, and a database written by the
shipped raw store adopts under GRDB cleanly:

- The GRDB migrator registers the current schema as `v1` with `IF NOT EXISTS`,
  so on a pre-existing raw-created database it records v1 as applied and only
  (idempotently) ensures the two v0.4.4 indexes.
- A test (`GRDBHistoryStoreTests.testAdoptsDatabaseWrittenByRawSQLiteStore`)
  wrote 25 rows with the raw store, opened the same file under GRDB, and
  confirmed every row survived — then wrote via GRDB and re-opened under the
  raw store with no rows gained or lost.

So data safety is **not** the reason for the decline. If GRDB were adopted,
the migration path is low-risk.

## Finding 2 — GRDB costs ~1.8× the allocations (the deciding number)

Same query (`entries(matching:)` over 50,000 rows), same machine, Release,
package-benchmark `mallocCountTotal`:

| Store | Mallocs (total) |
|---|---|
| `HistoryStore` (hand-rolled, prepared-statement cache) | **391** |
| `GRDBHistoryStore` (idiomatic GRDB, `Row.fetchAll`) | **700** |

GRDB allocates **~309 more objects per query (1.79×)**. The overhead is
inherent to its ergonomics: `Row` objects and column-name access versus the
raw path's cached prepared statements and positional column reads. A GRDB
expert could shave this with lower-level APIs — but doing so surrenders the
ergonomics that were the reason to adopt GRDB in the first place.

This query has a committed CI gate. To be exact about which number that is:
the enforced threshold is **1298** `mallocCountTotal` at p90, in
`Benchmarks/Thresholds/QwaveKitBenchmarks.HistoryStore.entries(matching:)_@_50k_rows.p90.json`
(checked by the `Benchmark thresholds (mallocCountTotal)` job in
`.github/workflows/ci.yml`). **391 is the measurement above, not the gate** —
the gate sits well above it, with headroom. Per the migration's own rule the
gate is not to be loosened to make an adoption pass; the reason to decline GRDB
is the 1.79× regression against the measured baseline, not a threshold breach.

## Finding 3 — the architecture makes per-store GRDB a fragile hybrid

`HistoryStore` and `BookmarkStore` share one `browser.db` file through a single
`SQLiteDatabase` handle. Migrating only `HistoryStore` to GRDB means either a
second database library opening a connection onto the same WAL file, or moving
`HistoryStore` to its own file with a data-copy migration. Either way, GRDB's
actual payoff — `ValueObservation` (live Library-window updates) and
`DatabasePool` (reader/writer separation) — only materialises if the **whole**
Persistence layer moves together. Per-store GRDB on a shared file gives the
risk without the reward.

## Recommendation

- **Keep raw SQLite for `HistoryStore`** (and the other stores). It is faster
  (391 vs 700 mallocs), already Swift-6-clean, and one fewer shipped
  dependency in a browser whose thesis is auditability.
- **Revisit only as a whole-layer decision.** If live-updating the Library
  window from `ValueObservation` becomes a priority, evaluate migrating *all*
  of Persistence to GRDB at once (so the architecture is clean and the payoff
  is real), and re-measure against the committed threshold at that time
  (currently 1298 `mallocCountTotal` p90 — not 391, which is the raw path's
  measured count).

## Reproduction

The evaluation `GRDBHistoryStore` and its tests are not committed (to keep the
shipped package free of an unused dependency). To reproduce: add
`.package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1")` to
`Packages/QwaveKit/Package.swift`, add `GRDBHistoryStore` mirroring
`HistoryStore`, add a `GRDBHistoryStore.entries(matching:) @ 50k rows`
benchmark alongside the existing `HistoryStore` one, and run
`swift package benchmark run --filter '.*istory.*'`.
