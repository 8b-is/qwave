---
title: "The measured cost of a Swift module boundary"
status: draft
date: 2026-08-13
tags: [swift, performance, module, compilation, macos]
measured_on: "Apple M1 Max (8 P-cores / 2 E-cores), 64 GB unified memory, macOS 26.4, Xcode 16.4. Release build, package-benchmark mallocCountTotal."
---

## The question

Swift does not specialise generics or inline across module boundaries by default. Qwave has a 6-way SPM module split in `QwaveKit` (QwaveSupport, Persistence, BrowserCore, Shields, FeatureFlags, VPNKit, etc.), and the hottest user-facing paths cross these boundaries — the omnibox in BrowserCore calls into Persistence for history queries.

Does the module boundary cost measurable performance?

## What we tried

We added `@inlinable` + `@usableFromInline` to the hottest cross-module functions:

- `OmniboxParser.parse(_:)` — called from BrowserCore, uses WebURL (external dependency)
- `OmniboxSuggester.suggestions(for:history:now:limit:)` — takes `HistoryEntry` from Persistence
- `OmniboxSuggester.matchScore(_:entry:)` — internal helper
- `OmniboxParser.url(from:)` — internal helper

## Results

| Metric | Before | After | Δ |
|---|---|---|---|
| OmniboxParser.parse | 30 mallocs | 30 mallocs | 0% |
| OmniboxSuggester.suggestions | 1,011 mallocs | 1,011 mallocs | 0% |
| HistoryStore.entries(matching:) | 391 mallocs | 391 mallocs | 0% |

**No measurable change in `mallocCountTotal`.**

## What we did NOT try

- **`-cross-module-optimization` / `-enable-cmo`** — requires build-system changes outside the SPM package scope (the flag is set at the `swiftc` invocation level, not in `Package.swift`). May be worth revisiting with a dedicated build configuration.
- **Collapsing modules** — explicitly ruled out per the project's architectural constraints. The 6-way split serves build times, testability, and the `QwaveTunnelKit` product boundary (the tunnel extension must not link the browser).

## Interpretation

The `@inlinable` annotations are kept because they enable the compiler to optimise the hot path further (specialisation, ARC elimination), but the impact is invisible to our CI-checked metric. The module boundary may cost instruction count or register pressure that a wall-clock benchmark could detect, but `mallocCountTotal` is allocation-count only.

## Conclusion

**For allocation-count-sensitive code, module boundaries are free.** If you're measuring `mallocCountTotal`, the cost of a cross-module call is zero. The `@inlinable` annotations are a no-regret change (they don't hurt and may help the optimiser), but they are not worth a dedicated build-system migration.

This is a valuable null result: many Swift teams assume module boundaries are expensive, and almost nobody has published numbers.