# SafariConverterLib

| Fact | Value |
|---|---|
| **Repo** | https://github.com/AdguardTeam/SafariConverterLib |
| **Latest version** | v4.3.0 (verified 2026-08-13) |
| **License** | GPL-3.0 (verified in LICENSE at v4.3.0) |
| **Platforms** | macOS / cross-platform Swift |
| **Apple Silicon status** | ✅ Native |

> **Correction (2026-08-13):** the original note misattributed this to a
> WebKit-project "WebKitAdditions" component with an LGPL-family license. It
> is AdGuard's Swift library, GPL-3.0. License review passed for use as an
> external **build-time** tool only — see [docs/BLOCKLIST.md](../../docs/BLOCKLIST.md)
> for the boundary conditions (never link/vendor it into shipped targets,
> never ship its advanced-blocking JS; EasyList output shipped under the
> CC BY-SA 3.0 branch with attribution). Adopted in v0.3.0 via
> `scripts/update-blocklist.sh`.

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
