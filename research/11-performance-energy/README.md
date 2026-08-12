# 11 · Performance & Energy

| Package | Version | Verdict | Qwave module |
|---------|---------|---------|--------------|
| [package-benchmark](package-benchmark.md) | 1.36.2 (Jul 24, 2026) | 🔵 Trial | `BrowserCore`, `Persistence` |

---

## Why this category exists

Qwave's README makes a measurable claim:

> **Energy Governor**: `TabHibernator` memory manager that unloads background WebKit processes
> while preserving tab state and scroll position.

**Nothing in the repository measures it.** `EnergyGovernorTests` and `HibernationControllerTests`
verify the *logic* — that the right decisions are made — but no test verifies the *outcome*: that
memory is actually reclaimed, and how much.

That gap matters more here than it would elsewhere. Memory and battery are not a feature of this
product; they are the product. A regression that quietly halves the reclamation rate would ship
undetected, and users would experience it as "the browser got worse" with nothing in CI to catch
it.

## What is worth measuring

| Metric | Where | Why |
|--------|-------|-----|
| Resident memory before/after hibernation | `TabHibernator` | The core product claim |
| Wake latency | `HibernationController` | The cost the user pays for the memory |
| `WKContentRuleList` compile time | `Shields/RuleListCompiler` | Grows with rule count — see [SafariConverterLib](../01-webkit-browser-engine/safari-converter-lib.md) |
| History query latency at scale | `Persistence/HistoryStore` | Degrades as the database grows over months |
| Session restore time | `SessionRestorer` | Directly felt at launch |
| Omnibox parse time | `OmniboxParser` | Runs on every keystroke |

The first two are the ones the product story depends on.

## The platform tools

Not everything belongs in a benchmark package. The measurement stack worth using:

| Tool | Use |
|------|-----|
| **`os_signpost`** | Instrument hibernate/wake in `QwaveSupport/Log.swift`; visible in Instruments |
| **Instruments — Energy Log** | Real battery impact, the only ground truth for energy claims |
| **`XCTMetric`** | `XCTMemoryMetric` and `XCTClockMetric` in existing XCTest suites |
| **[package-benchmark](package-benchmark.md)** | Regression thresholds enforced in CI |
| **`MetricKit`** | Field data from real usage, if telemetry is ever acceptable |

`MetricKit` deserves a note: it reports to Apple, not to a third party, and is opt-in at the OS
level. That makes it *less* objectionable than typical telemetry for a sovereign browser — but
"less objectionable" is still a product decision, not a technical one, and it should be made
explicitly rather than by adding a framework.

## The honest limitation

A benchmark package measures **in-process** cost. Qwave's most important number —
`WKWebView` content process memory — lives in **other processes** that WebKit manages.

So the measurement strategy has to be layered:

- **package-benchmark** for in-process work: parsing, SQLite queries, rule compilation.
- **Instruments and `XCTMemoryMetric`** for whole-system memory, which is where the hibernation
  claim actually lives.

Neither alone is sufficient, and mistaking the first for the second would produce green
benchmarks alongside a regressed product.
