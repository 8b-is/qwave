# Tuist

| Fact | Value |
|---|---|
| **Repo** | https://github.com/tuist/tuist |
| **Latest version** | 4.x (2026-08, re-verify) |
| **License** | MIT |
| **Platforms** | macOS (CLI) |
| **Apple Silicon status** | ✅ Native |

## What it is

A full project-generation-and-more toolchain: XcodeProj, project
    description, selective testing, caching.

## Why it matters for Qwave

- Replacing XcodeGen with Tuist buys remote/selective test caching —
      attractive once the suite grows past the ~25-minute full run.
    - Migration cost is real and touches every workflow.

## Apple Silicon notes

- arm64-native CLI.

## Adoption sketch

- Keep on the radar; revisit if CI time becomes the bottleneck.

## Risks

- Big conceptual jump from XcodeGen; onboarding cost; another DSL.

## Verdict: Assess — revisit when CI time hurts
