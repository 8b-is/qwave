# Yams

| Fact | Value |
|---|---|
| **Repo** | https://github.com/jpsim/Yams |
| **Latest version** | 5.x (2026-08, re-verify) |
| **License** | MIT |
| **Platforms** | All Swift platforms |
| **Apple Silicon status** | ✅ Native |

## What it is

YAML parser/emitter for Swift (LibYAML-backed).

## Why it matters for Qwave

- `project.yml` is XcodeGen's concern, not Qwave's runtime; YAML has no
      place in the app itself.

## Apple Silicon notes

- Native.

## Adoption sketch

- Skip.

## Risks

- C LibYAML dependency for zero runtime need.

## Verdict: Hold
