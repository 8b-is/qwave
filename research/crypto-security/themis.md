# Themis

| Fact | Value |
|---|---|
| **Repo** | https://github.com/cossacklabs/themis |
| **Latest version** | 0.14.x (2026-08, re-verify) |
| **License** | Apache-2.0 |
| **Platforms** | macOS / iOS / Linux |
| **Apple Silicon status** | ✅ Works (C core) |

## What it is

High-level crypto (secure cell/message/session) with a C core.

## Why it matters for Qwave

- Nothing in Qwave needs a session-layer crypto library; WireGuard and
      WebKit already own those layers.

## Apple Silicon notes

- C core builds fine on arm64.

## Adoption sketch

- Skip.

## Risks

- Redundant abstraction over primitives Qwave already manages.

## Verdict: Hold
