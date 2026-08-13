# GRDB

> **Status 2026-08-13 (v0.4.4+): evaluated and DECLINED for `HistoryStore`.**
> A parallel GRDB 7.11.1 `HistoryStore` was built, proven migration-safe
> against a real raw-SQLite database, and benchmarked: idiomatic GRDB costs
> **700 mallocs vs the hand-rolled path's 391** (~1.8×) for the same 50k-row
> query, and the shared `browser.db` file means per-store GRDB is a fragile
> hybrid without the `ValueObservation` payoff. Kept raw SQLite. Full
> measurement and the "revisit only as a whole-layer decision" reasoning:
> [docs/GRDB-EVALUATION.md](../../docs/GRDB-EVALUATION.md)..swift

| Fact | Value |
|---|---|
| **Repo** | https://github.com/groue/GRDB.swift |
| **Latest version** | 7.11.1 (verified 2026-08-12) |
| **License** | MIT |
| **Platforms** | macOS / iOS / tvOS / watchOS / Linux / Windows |
| **Apple Silicon status** | ✅ Native (pure Swift + SQLite) |

## What it is

A toolkit for SQLite databases in Swift: raw SQL, the query interface,
    record types, migrations, WAL, and full Swift concurrency support.

## Why it matters for Qwave

- **Persistence**: Qwave's hand-rolled SQLite layer (raw `sqlite3` calls)
      is correct but bare; GRDB gives typed models, migrations and `async/await`
      access with zero behaviour change — same SQLite file format.
    - History/bookmark/session stores get compile-time-checked queries.

## Apple Silicon notes

- Pure Swift on arm64; WAL mode is the same on-disk format Qwave already
      uses, so migration is drop-in.

## Adoption sketch

- Adopt incrementally in `Persistence` behind the existing store
      protocols; start with migrations.

## Risks

- Touches the most sensitive subsystem (user history). Swap in a branch,
      run the full persistence test suite, compare DB files byte-for-byte.

## Verdict: Adopt (incremental)
