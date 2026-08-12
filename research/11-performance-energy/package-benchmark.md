# package-benchmark (`ordo-one/package-benchmark`)

| | |
|---|---|
| **Repo** | https://github.com/ordo-one/package-benchmark |
| **Version** | **1.36.2** (2026-07-24) |
| **License** | Apache 2.0 |
| **Platforms** | macOS, Linux |
| **Apple Silicon** | Native |
| **Verified** | 2026-08-12 |

---

## What it is

A SwiftPM plugin for benchmarking with **regression detection built in**. It measures far more
than wall-clock time: CPU time (user and system), memory allocations, retain/release traffic,
peak resident memory, syscalls, and context switches — reporting percentiles rather than
averages.

The feature that matters is **baselines**. Record a baseline, commit it, and CI fails when a
change regresses beyond a configured threshold. That turns performance from something you notice
eventually into something the build enforces.

## Why it matters for Qwave

Qwave's README claims battery and memory optimisation. `EnergyGovernorTests` and
`HibernationControllerTests` verify decision logic; nothing measures outcomes. This package is
how the measurable half of that gets enforced.

### What it can measure well

```swift
// Benchmarks/BrowserCore/OmniboxBenchmarks.swift
import Benchmark

let benchmarks = {
    Benchmark("OmniboxParser.parse",
              configuration: .init(metrics: [.cpuTotal, .mallocCountTotal, .peakMemoryResident])) { bm in
        for _ in bm.scaledIterations {
            blackHole(OmniboxParser.parse("https://example.com/some/path?q=1"))
        }
    }
}
```

The strong candidates, all in-process:

| Benchmark | Module | Why |
|-----------|--------|-----|
| Omnibox parsing | `BrowserCore/OmniboxParser` | Runs on every keystroke; allocation count matters as much as time |
| History query at scale | `Persistence/HistoryStore` | Degrades as the database grows over months of use |
| Rule list compilation | `Shields/RuleListCompiler` | Scales with rule count — critical if the blocklist grows |
| Session restore | `BrowserCore/SessionRestorer` | Directly felt at launch |
| Relay selection | `VPNKit/RelaySelector` | Runs over the full relay list |

The `mallocCountTotal` metric is particularly apt. On Apple Silicon, allocation traffic often
matters more than raw instruction count, and it is a stable, machine-independent number —
unlike wall-clock time, which varies with CI runner load.

### What it cannot measure

**The hibernation claim itself.** `TabHibernator` reclaims memory by tearing down `WKWebView`
instances, and that memory lives in **WebKit's content processes** — separate processes that an
in-process benchmark cannot see.

For that, the tools are `XCTMemoryMetric` in an integration test and Instruments' Energy Log.
See the [category README](README.md) for the layered strategy. Treating in-process benchmarks as
coverage of the memory claim would produce green CI alongside a regressed product, which is worse
than no measurement at all.

## Apple Silicon notes

Native, and its metrics are Apple Silicon-appropriate: allocation counts and retain/release
traffic are more stable and more meaningful than cycle counts on a platform with aggressive
frequency scaling and heterogeneous cores.

One CI caution: benchmark numbers vary between runner classes, and between an M-series runner and
anything else. Baselines are only comparable on consistent hardware — pin the runner type, or
treat cross-runner comparisons as noise.

## Adoption sketch

```swift
// Packages/QwaveKit/Package.swift
.package(url: "https://github.com/ordo-one/package-benchmark", from: "1.36.2"),
.executableTarget(
    name: "BrowserCoreBenchmarks",
    dependencies: [
        "BrowserCore",
        .product(name: "Benchmark", package: "package-benchmark"),
    ],
    path: "Benchmarks/BrowserCore",
    plugins: [.plugin(name: "BenchmarkPlugin", package: "package-benchmark")]
)
```

```bash
swift package --package-path Packages/QwaveKit benchmark baseline update main
swift package --package-path Packages/QwaveKit benchmark baseline check main
```

Start with **`OmniboxParser`**: it runs on every keystroke, it is pure in-process work, it has
existing tests, and it is the natural place to prove the value of the
[WebURL](../01-webkit-browser-engine/weburl.md) migration in measured terms rather than asserted
ones.

## Risks

- **CI variance.** Benchmarks on shared runners are noisy. Use generous thresholds initially, and
  prefer allocation counts over wall-clock time — they are deterministic.
- **Cannot see the main claim.** Restated because it is the thing most likely to be misunderstood:
  hibernation memory is out of process.
- **Maintenance burden.** Baselines need updating when performance legitimately changes. A stale
  failing benchmark gets disabled, and then measures nothing.
- **Adds a build target.** Benchmarks compile alongside the package, so CI time grows. Run them on
  a schedule rather than per-PR if that becomes a problem.

## Verdict

🔵 **Trial — start with `OmniboxParser`, and be clear about what it does not cover.**

Qwave makes performance claims that nothing currently measures, and this package turns the
in-process half of that into an enforced regression gate.

The caveat is essential rather than incidental: **it cannot measure the hibernation memory claim**,
which is the headline. That needs `XCTMemoryMetric` and Instruments. Adopting this package while
believing it covers the memory story would be worse than not adopting it.

**Sequence:** one benchmark on `OmniboxParser`, a committed baseline, a CI check with a generous
threshold. Expand once the noise characteristics of the runners are understood.
