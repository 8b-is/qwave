# SQLite.swift

| Fact | Value |
|---|---|
| **Repo** | https://github.com/stephencelis/SQLite.swift |
| **Latest version** | 0.15.x (2026-08, re-verify) |
| **License** | MIT |
| **Platforms** | macOS / iOS / tvOS / watchOS / Linux |
| **Apple Silicon status** | ✅ Native (thin SQLite binding) |

## What it is

A minimal, well-known Swift wrapper over the C SQLite library.

## Why it matters for Qwave

- Subset of GRDB; if GRDB is adopted, this is redundant.

## Apple Silicon notes

- Fine on arm64; nothing special.

## Adoption sketch

- Skip — GRDB covers the same ground with better typing.

## Risks

- Divergent API surface from GRDB; two SQLite wrappers = confusion.

## Verdict: Hold — use GRDB instead
