# Summarize — design

**Status:** shipped in **v1.0.0** — the tag contains
`Packages/QwaveKit/Sources/Summarize/` and `Sources/QwaveApp/SummarizePanel.swift`
(`git show v1.0.0:Packages/QwaveKit/Sources/Summarize/SummarizeSession.swift`),
and the release was published minutes after the feature commit. The CHANGELOG
still lists the feature under `[Unreleased]`; that placement was already stale
when the tag was cut, and is a CHANGELOG bug rather than a statement about what
shipped. · **Stamps:** 2026-08-14 · macOS 26.4.1 (25E253) · M1 Pro ·
FoundationModels from macOS 26.4 SDK · measured numbers from
`research/02-on-device-ai/foundation-models-probe/`

One-page contract for the page-summarisation feature. It is the axis-02 notes'
spec made concrete: **Optional · Local · Energy-aware · vanish-cleanly**, and
"never automatic, never speculative, never background."

## What it is

"Summarize Page" (menu command + omnibox affordance): on explicit user command,
extract the article text from the current tab with the readability script and
run it through Apple's on-device FoundationModels `LanguageModelSession`.
The summary renders as **inert, selectable text** in a panel. Nothing
downstream of the model touches browser state — no links resurrected into
navigation, no settings writes, no shields changes.

## Hard rules

1. **Respond-only. No streaming code path exists.** On macOS 26.4.1 the
   `streamResponse` path refuses page-summarisation content deterministically
   ("May contain sensitive content") while `respond` accepts the same input
   (probe finding 1, `foundation-models-probe/README.md`). A try-stream-fall-
   back ladder would tax every summary with a guaranteed-failed call and keep
   alive a code path whose stricter filter emits refusal copy we never want
   near the UI. Re-evaluate by re-running the probe per macOS release —
   a research task, not runtime logic.
2. **Retry ≤3 on refusal, then quiet failure.** `respond` refusals are
   nondeterministic noise, not a content verdict (probe finding 2). Bounded
   at the probed ≤3 attempts, surfaced to logs with the refusal count; the UI
   string is "Couldn't summarize this page." The words "sensitive content"
   never render. No per-page "refused" state is persisted.
3. **Availability tri-state, from the probe:** check
   `SystemLanguageModel.default.availability` before showing the feature.
   - `available` → feature present.
   - `unavailable(.modelNotReady)` → **self-heals** (the OS publishes the
     model later); re-check on app foreground, never cache "unavailable".
   - `unavailable(.deviceNotEligible | .appleIntelligenceNotEnabled)` → the
     feature **vanishes cleanly**: no menu item, no grey-out, no explanation,
     no nag. `appleIntelligenceNotEnabled` is a user setting; respect it
     silently.
4. **Energy gate:** the command consults `EnergyGovernor` (including the
   `underMemoryPressure` input). Not `.normal` → the command quietly does
   nothing this moment; inference is exactly why that input exists.
5. **Extraction provenance:** the product extractor is the probe's script,
   byte-identical or fork-documented, so the F1 numbers keep meaning:
   **1.00 / 1.00 / 1.00 / 1.00 / 0.96** (news-article, docs-page,
   dense-technical, paywalled-teaser, spa-rendered) from
   `readability-probe/README.md`. The <20-char filter's known cost (short
   table cells) is a comment in the script, not a rewrite. Boilerplate
   filtering happens at extraction time (the paywall-leak fix), and the
   readyState-race fallback is kept verbatim.
6. **Prompts stay simple, validation stays loose.** The model mutates under OS
   updates (probe culture: change one variable per run). No prompt jenga.

## UX (honest about the cost)

- Trigger: menu command (and omnibox affordance) → spinner with **Cancel**
  (cancel abandons the `respond` task; warm reality is **12–16 s per summary**
  on M1 Pro, probe latency table).
- `prewarm(promptPrefix:)` is fired **only on explicit intent** (menu open),
  never on page load; measured delta is a footnote below (P1c).

## Compile-surface gate

All FoundationModels touchpoints sit behind `#if canImport(FoundationModels)` +
`#available(macOS 26, *)`. The macOS 14 floor and the universal
(arm64+x86_64) build compile untouched on any SDK — same discipline as the
`_WKFeature` tri-state work. The module is absent on unsupported systems; the
app builds and runs fully without it (non-negotiable 1).

## Non-goals

No chat, no follow-ups, no background summarisation, no automatic anything,
no model output in navigation/shields/settings, no provider abstraction
(see seam finding — the SDK's real extension point is
`SystemLanguageModel.Adapter` asset packaging; a hand-rolled protocol layer
for "future MLX" is architecture the platform contradicts).

## Measured notes

- Summarisation quality: strong at this model's scope (accurate on the
  dense-technical fixture); hallucination-resistance observed; reasoning
  ceiling **unverified** (v2 probe deferred).
- **Prewarm: measured, no win — hook kept because it is free.**
  `prewarm(promptPrefix: nil)` costs ~12 ms and does not meaningfully cut
  first-call `respond` latency: alternating fresh-process runs on
  news-article (2 samples each, M1 Pro, macOS 26.4.1, release): control
  **7059 / 9630 ms** vs prewarm **6396 / 9538 ms** — well inside the
  same-day run-to-run variance (2.7–12.2 s observed for this fixture).
  The menu-open hook stays (explicit intent, zero cost), but claims no
  win; first-call warmth comes from the OS model service, not the app.
  Reproducible via `--prewarm` in the foundation-models-probe
  (`results/prewarm-2026-08-14.json`).
