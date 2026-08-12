# swift-png

| Fact | Value |
|---|---|
| **Repo** | https://github.com/tayloraswift/swift-png |
| **Latest version** | 4.4.x (2026-08, re-verify) |
| **License** | Apache-2.0 |
| **Platforms** | All Swift platforms |
| **Apple Silicon status** | ✅ Native (pure Swift) |

## What it is

Pure-Swift PNG encode/decode with no libpng dependency.

## Why it matters for Qwave

- Favicon pipeline / tab snapshot export without dragging in a C
      library; deterministic output good for tests.

## Apple Silicon notes

- Pure Swift — zero binary risk.

## Adoption sketch

- Adopt when favicon/snapshot export is implemented.

## Risks

- Performance below libpng for huge images; fine for icons.

## Verdict: Assess
