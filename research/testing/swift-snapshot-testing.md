# swift-snapshot-testing

| Fact | Value |
|---|---|
| **Repo** | https://github.com/pointfreeco/swift-snapshot-testing |
| **Latest version** | 1.1x (2026-08, re-verify) |
| **License** | MIT |
| **Platforms** | macOS / iOS / tvOS / Linux |
| **Apple Silicon status** | ✅ Native |

## What it is

Snapshot testing for values, JSON, and (via plugins) images/views.

## Why it matters for Qwave

- Golden tests for `UBORuleListCompiler` output JSON and the content-
      rule resources; catches silent regex regressions.

## Apple Silicon notes

- Pure Swift.

## Adoption sketch

- Adopt for Shields JSON goldens.

## Risks

- Snapshot churn on intentional changes; review discipline needed.

## Verdict: Trial
