# swift-testing

| Fact | Value |
|---|---|
| **Repo** | https://github.com/swiftlang/swift-testing |
| **Latest version** | bundled with Xcode 26/27 (2026-08) |
| **License** | Apache-2.0 (Swift license) |
| **Platforms** | All Swift platforms |
| **Apple Silicon status** | ✅ Native |

## What it is

Apple's next-generation test framework (parameterised tests, rich
    diagnostics), shipping with the toolchain.

## Why it matters for Qwave

- Qwave's 150-test suite is XCTest; swift-testing coexists with it and
      is better for the crypto KATs (parameterisation over vector sets).
    - Free — no dependency; part of the toolchain.

## Apple Silicon notes

- Native everywhere.

## Adoption sketch

- New tests (PostQuantum vector loops) in swift-testing; migrate the
      rest opportunistically.

## Risks

- Mixed XCTest/swift-testing targets need Xcode 16+; CI already has it.

## Verdict: Adopt (new tests)
