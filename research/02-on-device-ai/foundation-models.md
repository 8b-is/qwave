# Foundation Models (`import FoundationModels`)

| | |
|---|---|
| **Source** | Apple platform framework |
| **Introduced** | WWDC25 (iOS 26 / macOS 26); expanded at WWDC26 |
| **Availability** | macOS 26+ on Apple Silicon with Apple Intelligence |
| **License** | Apple SDK |
| **Apple Silicon** | Required — runs on the Neural Engine / GPU |
| **Verified** | 2026-08-12 |

---

## What it is

Apple's on-device LLM, exposed to third-party apps through a small Swift API. The model is a
compact **~3 billion parameter** LLM **quantised to roughly 2 bits per weight**, so it runs
fast, offline, and entirely on the user's device. It is competent at summarisation, extraction,
short-form generation, and structured reasoning — and explicitly not a frontier model.

The entire integration is three moving parts: `import FoundationModels`, create a
`LanguageModelSession`, call `respond`.

**WWDC26 removed the framework's one hard rule.** Until this year it was Apple's on-device model
or nothing. Session 339 introduced a public protocol layer that *any* LLM can implement — a
cloud API, a local open-source model, a self-hosted fine-tune. Once a provider ships a
conforming Swift package, existing `LanguageModelSession` code works against it unchanged.

## Why it matters for Qwave

This is the **cheapest possible path to a credible on-device AI feature**, and for a browser
the economics are decisive:

| | Foundation Models | [MLX Swift](mlx-swift.md) |
|--|-------------------|---------------------------|
| Model download | **None** — part of the OS | 1–20 GB |
| App bundle impact | **Zero** | Zero, plus a download subsystem |
| Storage management | **Apple's problem** | Yours |
| Model updates | **Ships with the OS** | Yours |
| Integration size | Three lines | A subsystem |

For **page summarisation** — the one AI feature that clearly belongs in a privacy-first browser
— a 3B model is genuinely adequate. Summarising visible article text is exactly the task class
this model was built for.

The WWDC26 provider protocol is the strategic unlock: write the feature against
`LanguageModelSession` once, and the backend becomes swappable. If Apple's model proves too
small, swap in an MLX-backed provider without touching the call sites. That converts an
architectural decision into a configuration one.

## Apple Silicon notes

- **Requires Apple Silicon with Apple Intelligence support** running macOS 26+. Apple's own
  guidance for coding along with the framework is exactly this configuration.
- The 2-bit quantisation is what makes a 3B model practical to keep resident alongside a
  browser's working set — the memory footprint is a fraction of an equivalent MLX deployment,
  which matters enormously when WebKit content processes are competing for the same pool.
- The model is shared across the system, so it is not per-app resident memory. Compare with
  MLX, where every app pays full freight for its own weights.

## Adoption sketch

```swift
// A new optional QwaveKit module — say, Assist
import FoundationModels

@available(macOS 26.0, *)
struct PageSummariser {
    func summarise(_ articleText: String) async throws -> String {
        // EnergyGovernor is a pure conditions → tier mapping; .normal gates discretionary work.
        guard EnergyGovernor.tier(for: currentConditions) == .normal else {
            throw AssistError.deferred
        }
        let session = LanguageModelSession()
        let response = try await session.respond(
            to: "Summarise the following page in three sentences:\n\n\(articleText)"
        )
        return response.content
    }
}
```

Wire it to an explicit user action — a toolbar item or a menu command in `MainMenu.swift`.
Never automatic, never speculative, never background.

Extracting the article text is the other half of the work and belongs in `BrowserCore`: a
readability-style `WKUserScript` that pulls main content out of the DOM. That is the piece worth
prototyping first, because it is required regardless of which model backend wins.

## Risks

- **macOS 26 floor plus a hardware floor.** Not every Apple Silicon Mac supports Apple
  Intelligence. Availability must be checked at runtime and the feature must vanish cleanly when
  absent — not error, not grey out with an explanation nobody reads.
- **~3B is small.** Fine for summarisation and extraction. Not fine for long-context reasoning
  over a full page of dense technical content. Set the feature's scope to what the model can
  actually do.
- **No control over model updates.** The model changes when the OS changes. Prompts that work
  today can drift. Keep prompts simple and outputs loosely validated.
- **Apple Intelligence carries user-facing settings.** The user may have it disabled entirely.
  Respect that without nagging.
- **Content extraction is the real work.** Getting clean article text out of an arbitrary page
  is harder than the inference call. Budget for it.

## Verdict

🔵 **Trial — the correct first AI feature for Qwave, if there is to be one.**

Zero download, zero bundle growth, zero model management, three lines of integration, and the
WWDC26 provider protocol means the backend stays swappable. There is no cheaper way to find out
whether on-device summarisation is a feature Qwave's users actually want.

**Sequence:** build the readability extraction script first and verify it produces clean text
across a realistic sample of pages. That is the hard part and it is backend-independent. The
model call is the easy part.

---

**References:**
[What's new in the Foundation Models framework — WWDC26 session 241](https://developer.apple.com/videos/play/wwdc2026/241/) ·
[Bring an LLM provider to the Foundation Models framework — WWDC26 session 339](https://developer.apple.com/videos/play/wwdc2026/339/)
