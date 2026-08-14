# Blog Drafts

> Performance findings from the Qwave optimisation session (2026-08-13).
> **Drafts only — nothing here is published, reviewed, or final.**

| File | Status | Topic | Target |
|---|---|---|---|
| [measuring-memory-a-browser-doesnt-own.md](measuring-memory-a-browser-doesnt-own.md) | draft | proc_pid_rusage over WebContent pid-set difference | — (long-form) |
| [what-59657-blocking-rules-cost.md](what-59657-blocking-rules-cost.md) | draft | WKContentRuleList compile time, stale-while-revalidate | — (long-form) |
| [zero-allocation-text-on-the-keystroke-path.md](zero-allocation-text-on-the-keystroke-path.md) | draft | 4,370→1,011 mallocs, Substring, bounded heap | **pocoo.vaked.dev** (published) |
| [measured-cost-of-a-swift-module-boundary.md](measured-cost-of-a-swift-module-boundary.md) | draft | @inlinable experiment, null result | — (long-form) |
| [why-we-benchmark-allocations-not-wall-clock.md](why-we-benchmark-allocations-not-wall-clock.md) | draft | mallocCountTotal methodology, CI rationale | — (long-form) |
| [app-intents-and-spotlight-ecosystem-integration.md](app-intents-and-spotlight-ecosystem-integration.md) | draft | App Intents + CoreSpotlight: zero-config OS integration, @MainActor bridge, Swift 6 sharp edges | — (long-form) |
| [where-metal-pays-in-a-webkit-browser.md](where-metal-pays-in-a-webkit-browser.md) | draft | WebGL wave stays in WebKit's GPU process; GPU demand control (30 fps, visibility pause) | — (long-form) |
| [polling-is-a-battery-bug-notification-driven-energy-policy.md](polling-is-a-battery-bug-notification-driven-energy-policy.md) | draft | 40s energy-reaction lag → notification-driven ticks; audit notes, API rename gotcha | — (long-form) |

## Assets

SVGs (versioned alongside the drafts, render in GitHub markdown) live in
[`assets/`](assets/). Everything except the `omnibox-*` /
`bounded-insertion-sort.svg` set was generated through the entheai engine
(`vaked` provider, deepseek-v3.2) and hand-polished for XML validity and layout.

| Asset | Used by |
|---|---|
| [assets/omnibox-keystroke-path.svg](assets/omnibox-keystroke-path.svg) | keystroke pipeline diagram (before/after malloc counts per stage) |
| [assets/omnibox-mallocs-before-after.svg](assets/omnibox-mallocs-before-after.svg) | headline bar chart: 4,370 → 1,011 mallocs (−77%) |
| [assets/bounded-insertion-sort.svg](assets/bounded-insertion-sort.svg) | full-sort-then-prefix-6 vs bounded top-6 illustration |
| [assets/blocklist-cold-vs-warm.svg](assets/blocklist-cold-vs-warm.svg) | cold compile 2.84 s vs warm load 0.135 s (−95%) |
| [assets/blocklist-stale-while-revalidate.svg](assets/blocklist-stale-while-revalidate.svg) | stale-while-revalidate launch flow |
| [assets/blocklist-pipeline.svg](assets/blocklist-pipeline.svg) | rules → JSON → compile → artifact pipeline |
| [assets/hibernation-process-tree.svg](assets/hibernation-process-tree.svg) | app process vs out-of-process WebContent processes |
| [assets/hibernation-reclaim.svg](assets/hibernation-reclaim.svg) | 137 MB → 0 MB reclaim bar chart |
| [assets/hibernation-wake-latency.svg](assets/hibernation-wake-latency.svg) | wake-to-interactive phase breakdown |
| [assets/module-boundary-inlining.svg](assets/module-boundary-inlining.svg) | what @inlinable does at a Swift module boundary |
| [assets/inlinable-null-result.svg](assets/inlinable-null-result.svg) | @inlinable Δ = 0% across malloc/retain/release |
| [assets/wallclock-vs-mallocs.svg](assets/wallclock-vs-mallocs.svg) | noisy wall-clock vs deterministic allocation counts |
| [assets/malloccount-sees-misses.svg](assets/malloccount-sees-misses.svg) | what mallocCountTotal catches vs misses |

## Code provenance

All code snippets and numbers in the drafts come from the actual repo. Inline
code links are pinned to a commit's blob so they stay accurate forever:

- **Keystroke / blocklist / module-boundary / methodology** — pinned to
  [`088f068`](https://github.com/8b-is/qwave/commit/088f0680efcefca542d427af20184574e693085c)
  (v0.5.0, the current `main`).
- **Headline omnibox commit:** [`15c1389`](https://github.com/8b-is/qwave/commit/15c1389aa0e2ccff5bf80cb85b62d7dcc6a2b6a9) —
  omnibox −77% allocs, SQLite statement cache, history indexes, blocklist JSON release.
- **Stale-while-revalidate:** [`4d0b533`](https://github.com/8b-is/qwave/commit/4d0b533bd43c6559644d1e8eb5250b10c7a236fe)
  (blocklist performance budget); EasyList snapshot in
  [`7928c38`](https://github.com/8b-is/qwave/commit/7928c3888c2d8cfa444078c315e4e698ef782ca4).
- **Hibernation measurement:** [`ba8caf0`](https://github.com/8b-is/qwave/commit/ba8caf0bc09614bfa980364937236902f518ebb5)
  (process-tree reclaim test); `warmProcessCount` wired in
  [`23f88e6`](https://github.com/8b-is/qwave/commit/23f88e6519cda31063f802829b00a3f46f172524).
- **Benchmark infra:** [`f3402ea`](https://github.com/8b-is/qwave/commit/f3402ea84d7bd3b808d55e9a64488832c315dd04)
  (in-process suite + CI thresholds); ARC metrics + 5% gate in
  [`dac7187`](https://github.com/8b-is/qwave/commit/dac7187919701d36b5fff2166bab89828f713bdd);
  jemalloc in [`2d3565a`](https://github.com/8b-is/qwave/commit/2d3565a560c45004fbbaa54d29bc3c4799bccb87).

Reproduce a regression by checking out the relevant commit and re-running
`swift package benchmark run` in `Benchmarks/`.
