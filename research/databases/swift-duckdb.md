# swift-duckdb

| Fact | Value |
|---|---|
| **Repo** | https://github.com/duckdb/duckdb-swift |
| **Latest version** | 1.2.x (2026-08, re-verify) |
| **License** | MIT |
| **Platforms** | macOS / iOS / Linux |
| **Apple Silicon status** | ✅ Native (C++ core via SPM binary targets) |

## What it is

DuckDB's analytical column-store engine for Swift — designed for OLAP,
    not OLTP.

## Why it matters for Qwave

- Browser telemetry/analytics (opt-in, local) is the classic DuckDB use
      case; Qwave has none today.
    - Could power an offline browsing-history search index later.

## Apple Silicon notes

- Ships prebuilt arm64 binaries via SPM; keep an eye on minimum macOS
      deployment target of the binaries.

## Adoption sketch

- Skip until analytics or full-text history search is scoped.

## Risks

- Heavy binary dependency (~10s of MB); supply-chain review needed.

## Verdict: Assess — revisit with analytics/FT-search features
