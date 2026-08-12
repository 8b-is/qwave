# swift-format

| Fact | Value |
|---|---|
| **Repo** | https://github.com/swiftlang/swift-format |
| **Latest version** | 603.0.0 (verified 2026-08-12) |
| **License** | Apache-2.0 (Swift license) |
| **Platforms** | macOS / Linux (CLI) |
| **Apple Silicon status** | ✅ Native |

## What it is

Apple's official Swift formatter and linter.

## Why it matters for Qwave

- Qwave has no enforced formatter; adding swift-format in CI
      (lint mode) raises review quality on the crypto-heavy modules.
    - Version tracks the Swift toolchain — pin to match CI's Swift.

## Apple Silicon notes

- arm64-native via swift toolchain.

## Adoption sketch

- Add a `swift-format lint` CI job; auto-format in pre-commit hooks later.

## Risks

- Formatting churn on 3.6k-line modules is a one-time diff; do it in a
      dedicated commit.

## Verdict: Adopt
