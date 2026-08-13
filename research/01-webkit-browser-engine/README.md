# 01 · WebKit & Browser Engine

The layer Qwave *is*. Nothing here is a nice-to-have — these packages touch `BrowserCore`,
`Shields`, and `FeatureFlags` directly.

| Package | Version | Verdict | Qwave module |
|---------|---------|---------|--------------|
| [WebKit for SwiftUI](webkit-for-swiftui.md) | macOS 26+ platform API | 🟢 Adopt (gated) | `BrowserCore`, `QwaveApp` |
| [WebURL](weburl.md) | 0.4.2 | 🟢 Adopt | `BrowserCore/OmniboxParser`, `Shields` |
| [SafariConverterLib](safari-converter-lib.md) | 4.3.0 | 🔵 Trial (build-time only) | `Shields/RuleListCompiler` |
| [adblock-rust](adblock-rust.md) | no tagged releases | 🟡 Assess | `Shields` |

---

## The through-line

Qwave's blocking story today is a **curated 51-rule `WKContentRuleList`**. That is a starting
point, not an engine. The two content-blocking entries in this category are the two credible
paths past it, and they are not equivalent:

- **SafariConverterLib** converts AdGuard/EasyList-syntax filter lists into the JSON
  `WKContentRuleList` already understands. It changes *what rules you have*, not *how blocking
  works*. Run it at build time and the shipped app gains nothing at runtime but a bigger,
  better rule file.
- **adblock-rust** is a different engine entirely, matching in-process rather than delegating
  to WebKit. Far more capable, far more invasive, and a Rust FFI boundary inside a sovereign
  browser is a real decision — not a dependency bump.

Take SafariConverterLib first. It is strictly additive and reversible.

## The URL problem

Every browser gets this wrong at least once. `URL` and `URLComponents` are RFC 3986-flavoured;
the web runs on the **WHATWG URL Standard**, and they disagree on cases that matter:
IDN/punycode hosts, empty hosts, backslash normalisation, percent-encoding sets.

That divergence is a security boundary in Qwave, not a cosmetic bug — `ShieldsPolicy` makes
per-host decisions, and `HTTPSFirstUpgrader` rewrites schemes. If Qwave's notion of "the host"
differs from WebKit's, a page can be shielded under one identity and loaded under another.
**WebURL** exists precisely to close that gap.
