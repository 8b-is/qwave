# SafariConverterLib

| Fact | Value |
|---|---|
| **Repo** | https://github.com/WebKit/WebKit (WebKitAdditions) |
| **Latest version** | WebKit tip (2026-08) |
| **License** | **Copyleft (LGPL family) — VERIFY BEFORE USE** |
| **Platforms** | macOS / cross-platform via WebKit |
| **Apple Silicon status** | ✅ Native |

## What it is

WebKit's own content-blocker compiler: transforms the WebKit
    content-blocker JSON (and, with helpers, filter lists) into compiled
    rule-list bytecode used by Safari itself.

## Why it matters for Qwave

- **51 rules is a demonstration, not a blocklist.** SafariConverterLib
      as a *build-time* tool scales Qwave's Shields to EasyList-size lists
      with zero new runtime dependencies — the compiled bytecode is exactly
      what WKWebView consumes.
    - Would slot next to `RuleListCompiler`/`UBORuleListCompiler` as a
      precompile step checked into the repo or shipped as resources.

## Apple Silicon notes

- WebKit's own compiler; bytecode is versioned with the engine —
      matches the WKWebView in Qwave's process exactly.

## Adoption sketch

- Build-time CLI: list text → JSON → compiled list → bundled resource.
      Replace the 51-rule starter list with a compiled EasyList snapshot.

## Risks

- **License gate is hard**: copyleft status must be confirmed with the
      exact files used; shipping derived bytecode may have obligations.
      No code until legal review.

## Verdict: Trial — gated on license review
