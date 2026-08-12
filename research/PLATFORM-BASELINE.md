# Platform Baseline (2026-08-12)

Everything in this research tree assumes the following floor. If a package
note says "Apple Silicon native", it means *these* assumptions.

| Item | State |
|---|---|
| **macOS shipping** | macOS 26 |
| **macOS in beta** | macOS 27 |
| **Xcode** | Xcode 27 — Apple Silicon-only; requires macOS 26.4+ |
| **Swift** | 6.4 toolchain, language modes 5 / 6 |
| **Apple Silicon generations** | M1–M4 shipping, M5 with second-generation Neural Accelerators |
| **Qwave deployment target** | macOS 14.0 (v0.2.0) — deliberately below the baseline for reach |

## Consequences for Qwave

1. **Rosetta is dead as a distribution path.** Xcode 27 itself no longer runs
   on Intel, so every future toolchain is arm64-first. All packages below were
   evaluated for arm64 correctness — no x86_64-only fallbacks survive.
2. **macOS 14 as the floor keeps Intel alive for us.** Qwave still ships a
   universal binary (`arm64` + `x86_64`); any new dependency must build for
   both until the floor is raised. Packages that are arm64-only (e.g. MLX
   Swift) are marked accordingly and must be gated, not assumed.
3. **Neural Accelerators change the energy math.** M5-class NPUs make
   on-device ML cheap enough to matter for browser features (translation,
   page summarisation, phishing heuristics). The `apple-silicon` category is
   the shopping list for that future; nothing there is adopted yet.

## Verification stamping

GitHub release pages do not display years; versions recorded as
"(verified 2026-08-12)" were confirmed live against the release page on that
date, others are marked "≈ (2026-08, re-verify)". Licenses are stated from
knowledge and MUST be re-verified before any code is written — in particular
SafariConverterLib's copyleft status is a hard adoption gate.
