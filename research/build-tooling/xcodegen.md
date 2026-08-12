# XcodeGen

| Fact | Value |
|---|---|
| **Repo** | https://github.com/yonaskolb/XcodeGen |
| **Latest version** | 2.46.0 (verified 2026-08-12) |
| **License** | MIT |
| **Platforms** | macOS (CLI) |
| **Apple Silicon status** | ✅ Native (CLI tool) |

## What it is

Generates `.xcodeproj` from a `project.yml` spec — already Qwave's
    single source of truth.

## Why it matters for Qwave

- Already in use (`project.yml`); the research verdict is "keep".
    - Any new module lands as a project.yml edit, never an Xcode hand-edit.

## Apple Silicon notes

- Homebrew binary is arm64-native.

## Adoption sketch

- Continue; pin in CI via brew or mint.

## Risks

- Upgrade churn occasionally changes generated project format — commit
      diffs and regenerate in CI to catch drift.

## Verdict: Adopt (already in use)
