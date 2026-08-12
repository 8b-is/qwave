# SwiftLint

| Fact | Value |
|---|---|
| **Repo** | https://github.com/realm/SwiftLint |
| **Latest version** | 0.65.0 (verified 2026-08-12) |
| **License** | MIT |
| **Platforms** | macOS (CLI) |
| **Apple Silicon status** | ✅ Native |

## What it is

The community linter — style rules beyond the compiler.

## Why it matters for Qwave

- Redundant if swift-format's lint mode is adopted; SwiftLint's rule
      catalogue is deeper (cyclomatic complexity, file length).

## Apple Silicon notes

- arm64-native binary via Homebrew/Mint.

## Adoption sketch

- Pick one: swift-format (official, format+lint) or SwiftLint
      (deeper rules). Don't run both.

## Risks

- Rule bikeshedding; pick a strict preset once and freeze.

## Verdict: Assess — one linter, not two
