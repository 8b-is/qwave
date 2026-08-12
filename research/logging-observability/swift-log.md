# swift-log

| Fact | Value |
|---|---|
| **Repo** | https://github.com/apple/swift-log |
| **Latest version** | 1.6.x (2026-08, re-verify) |
| **License** | Apache-2.0 (Swift license) |
| **Platforms** | All Swift platforms |
| **Apple Silicon status** | ✅ Native |

## What it is

Apple's structured-logging API with swappable backends (os_log,
    files, …).

## Why it matters for Qwave

- `QwaveSupport.QwaveLog` is a thin custom wrapper; swift-log gives
      the same categories with standard metadata, and an os_log backend
      preserves privacy redaction.

## Apple Silicon notes

- Native; os_log backend is the right default.

## Adoption sketch

- Wrap `QwaveLog` around swift-log (or replace it) — keep the existing
      category API so call sites don't churn.

## Risks

- Logging privacy: browser URLs must stay `private` in os_log.

## Verdict: Adopt
