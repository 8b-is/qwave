# GRDB.swift

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
