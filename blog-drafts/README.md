# Blog Drafts

> Performance findings from the Qwave optimisation session (2026-08-13).
> **Drafts only — nothing here is published, reviewed, or final.**

| File | Status | Topic | Target |
|---|---|---|---|
| [measuring-memory-a-browser-doesnt-own.md](measuring-memory-a-browser-doesnt-own.md) | draft | proc_pid_rusage over WebContent pid-set difference | — (long-form) |
| [what-59657-blocking-rules-cost.md](what-59657-blocking-rules-cost.md) | draft | WKContentRuleList compile time, stale-while-revalidate | — |
| [zero-allocation-text-on-the-keystroke-path.md](zero-allocation-text-on-the-keystroke-path.md) | draft | 4,370→1,011 mallocs, Substring, bounded heap | **pocoo.vaked.dev** (published) |
| [measured-cost-of-a-swift-module-boundary.md](measured-cost-of-a-swift-module-boundary.md) | draft | @inlinable experiment, null result | — |
| [why-we-benchmark-allocations-not-wall-clock.md](why-we-benchmark-allocations-not-wall-clock.md) | draft | mallocCountTotal methodology, CI rationale | — |

## Assets

SVGs (versioned alongside the drafts, render in GitHub markdown) live in
[`assets/`](assets/). The `hibernation-*` set was generated through the
entheai engine (`vaked` provider, deepseek-v3.2) and hand-polished; the
`omnibox-*` / `bounded-insertion-sort.svg` set was hand-authored.

| Asset | Used by |
|---|---|
| [assets/omnibox-keystroke-path.svg](assets/omnibox-keystroke-path.svg) | keystroke pipeline diagram (before/after malloc counts per stage) |
| [assets/omnibox-mallocs-before-after.svg](assets/omnibox-mallocs-before-after.svg) | headline bar chart: 4,370 → 1,011 mallocs (−77%) |
| [assets/bounded-insertion-sort.svg](assets/bounded-insertion-sort.svg) | full-sort-then-prefix-6 vs bounded top-6 illustration |
| [assets/hibernation-process-tree.svg](assets/hibernation-process-tree.svg) | app process vs out-of-process WebContent processes — *entheai-generated* |
| [assets/hibernation-reclaim.svg](assets/hibernation-reclaim.svg) | 137 MB → 0 MB reclaim bar chart — *entheai-generated* |
| [assets/hibernation-wake-latency.svg](assets/hibernation-wake-latency.svg) | wake-to-interactive phase breakdown — *entheai-generated* |

## Code provenance

All code snippets and numbers in the drafts come from the actual repo:

- **Headline commit:** [`15c1389`](https://github.com/8b-is/qwave/commit/15c1389aa0e2ccff5bf80cb85b62d7dcc6a2b6a9) —
  omnibox −77% allocs, SQLite statement cache, history indexes.
  Inline code links in the drafts are pinned to this commit's blob, so they
  stay accurate forever.
- **"Before" state:** parent commit
  [`5fe2b0a`](https://github.com/8b-is/qwave/commit/5fe2b0a5f9edaf0ca853bc7e7481b77fe22b702e) —
  check out and re-run `swift package benchmark run` in `Benchmarks/` to
  reproduce the regression.
- **Benchmark infra:** [`f3402ea`](https://github.com/8b-is/qwave/commit/f3402ea)
  (in-process suite + CI thresholds); omnibox originally landed in
  [`b940468`](https://github.com/8b-is/qwave/commit/b940468).
