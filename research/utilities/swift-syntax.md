# swift-syntax

| Fact | Value |
|---|---|
| **Repo** | https://github.com/swiftlang/swift-syntax |
| **Latest version** | 603.0.0 (2026-08, re-verify) |
| **License** | Apache-2.0 (Swift license) |
| **Platforms** | All Swift platforms |
| **Apple Silicon status** | ✅ Native |

## What it is

The Swift parser/lexer/syntax tree as a library — basis of macros and
    formatting.

## Why it matters for Qwave

- Only needed for custom Swift macros or source tooling; Qwave has
      neither. Pulled in transitively by swift-format.

## Apple Silicon notes

- Native.

## Adoption sketch

- Skip as a direct dependency.

## Risks

- Large; version-locked to the toolchain.

## Verdict: Assess — only if a macro use case appears
