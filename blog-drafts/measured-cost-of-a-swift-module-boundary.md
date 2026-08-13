---
title: "The measured cost of a Swift module boundary"
status: draft
date: 2026-08-13
tags: [swift, performance, module, compilation, macos]
measured_on: "Apple M1 Max (8 P-cores / 2 E-cores), 64 GB unified memory, macOS 26.4, Xcode 16.4 (Swift 6.3.1). Release build, package-benchmark mallocCountTotal + retainCount + releaseCount."
corrections: "v2 — M0 of the follow-up session found the original conclusion was based on mallocCountTotal alone, which misses ARC traffic. ARC metrics are now CI-gated. The core finding (no evidence of module-boundary overhead) is unchanged, but the framing is more precise."
---

## The question

Swift does not specialise generics or inline across module boundaries by default. Qwave has a 6-way SPM module split in `QwaveKit`. Does the module boundary cost measurable performance?

## What we checked

| Technique | Status | Measurement |
|---|---|---|
| WMO (whole-module opt) | ✅ Enabled by default in SPM Release | — |
| `final` on classes | ✅ All 34 public classes already `final` | No change needed |
| `any Protocol` existentials | ✅ None on hot paths | No change needed |
| `@inlinable` + `@usableFromInline` | ✅ Applied on hot functions | See below |
| `-cross-module-optimization` | ❌ Not enabled | Requires build-system change |

## ARC metrics

`package-benchmark` now tracks `.retainCount`, `.releaseCount`, and `.retainReleaseDelta` as CI gates (25% p90 tolerance) alongside `mallocCountTotal`. These are deterministic like malloc counts and capture what `mallocCountTotal` cannot — dispatch changes, ARC traffic, and specialisation.

| Benchmark | Retains | Releases | RetainReleaseΔ | mallocs |
|---|---|---|---|---|
| OmniboxSuggester (500 entries) | 6,536 | — | — | 1,011 |
| SessionRestorer (40 tabs) | 557 | 913 | 291 | 65 |
| UBORuleListCompiler (1k rules) | 82K | 116K | 5,254 | 50K |

## ARC baseline

The `@inlinable` annotations were already applied before ARC metrics were added, so a direct before/after comparison is not possible from this session. The ARC baselines above are recorded so that a future change to `@inlinable` or CMO can be evaluated against them.

## Conclusion

**No evidence of measurable module-boundary overhead was found.** The codebase is already well-optimised: all classes are `final`, WMO is enabled, and `any Protocol` existentials are absent from hot paths. The `@inlinable` annotations are kept as a no-regret change (they enable the optimiser to specialise across module boundaries), but their effect on ARC traffic is unquantified.

ARC metrics are now CI-gated, so any future module-boundary change will be caught if it affects retains or releases.

**Not checked:** `-cross-module-optimization` / `-enable-cmo` requires build-system changes outside the SPM package scope. May be worth revisiting.

**Not done:** Module collapse. The 6-way split serves build times, testability, and the `QwaveTunnelKit` boundary that keeps the tunnel from linking the browser.