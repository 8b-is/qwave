# readability-probe — heuristic article extraction, measured

Local-only extractor prototype (WKUserScript → clean article text), the
hard backend-independent half of the DIGEST Phase 3.4 sequence. Zero
network: the corpus is five committed local HTML fixtures (original text,
scripts stripped, attribution comments in each).

## Method

`Extractor/extractor.js` scores paragraph-ish nodes (length, sentence-final
punctuation, container hints), penalizes boilerplate contexts (nav/header/
footer/aside/ads/paywall/subscribe), climbs to the best container, and
extracts text nodes ≥20 chars. The harness loads each fixture in an
ephemeral WKWebView, injects the script, and writes `results.json`.
Quality = token-set precision/recall/F1 vs the hand-marked expected text.

## Results (2026-08-14, macOS 26.4.1)

| Fixture | P | R | F1 | container | notes |
|---|---|---|---|---|---|
| news-article | 1.00 | 1.00 | 1.00 | ARTICLE | semantic tags, byline, figure, quote |
| docs-page | 1.00 | 0.92 | 0.96 | MAIN.content | recall loss = short table cells (<20 chars) dropped by the length filter — design choice, not a miss |
| dense-technical | 1.00 | 1.00 | 1.00 | DIV | no class hints; code blocks kept |
| paywalled-teaser | 1.00 | 1.00 | 1.00 | ARTICLE.story | paywall/subscribe copy excluded (see bug below) |
| spa-rendered | 1.00 | 1.00 | 1.00 | DIV | no semantic article; generic divs |

## Measured-hacking log

- **v1 leaked paywall copy.** The boilerplate penalty applied at *scoring*
  but not at *extraction* — the container's paragraphs were taken
  wholesale, including div.paywall's text. Fixed by filtering extracted
  nodes with the same `closest()` boilerplate check. F1 on the teaser went
  0.88 → 1.00.
- **The leak checker lied twice**: "paid section" appears in the article's
  legit content, so a naive substring check flagged a false positive even
  after the fix. The real paywall copy ("Subscribe to continue", "free
  preview", "Join 120,000") is absent — verified by F1 1.00.
- The `document.readyState` race: the message handler can fire before the
  extractor script is injected on slow loads; the harness falls back to
  `evaluateJavaScript` after readyState==complete (hit once, kept as the
  fallback path).

## Reproduce

```sh
cd research/02-on-device-ai/readability-probe
swift run -c release   # writes results.json
```
