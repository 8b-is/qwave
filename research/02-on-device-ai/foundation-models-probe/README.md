# foundation-models-probe

Availability tri-state, latency, quality, and provider-seam verification for
Apple's on-device LLM (`import FoundationModels`) — the backend half of the
DIGEST Phase 3.4 sequence (readability extraction landed first in
`../readability-probe`).

Everything runs locally, zero network, on committed fixtures (the extractor
output of the five readability-probe pages). Machine stamps below.

**Stamps** · 2026-08-14 · M1 Pro · macOS 26.4.1 (Build 25E253) · release build ·
FoundationModels from macOS 26.4 SDK (Xcode 26.4.1)

---

## Headlines (findings first)

1. **The stream path refuses this workload on macOS 26.4.1; `respond` works.**
   `streamResponse` instantly throws `Refusal("May contain sensitive content")`
   for the page-summarisation prompt, while `respond` with the *same prompt,
   same session class, same text* accepts. Control: `streamResponse("Say hello
   in one short sentence.")` accepts ("Hello!"). So the stream path runs a
   stricter content filter than the respond path — or a buggy one. Design
   consequence for a summarise feature: **don't ship streaming responses for
   page summaries on this OS build**; use `respond` + a spinner, or fall back
   to `respond` on stream refusal. TTFT is therefore reported as
   *unavailable* for this workload (the one number we could not measure, and
   why).
2. **The refusal is nondeterministic even on `respond`.** The same news-article
   text + prompt accepted 4/4 in the guardrails matrix, then refused 2/2 in
   the fixture loop minutes later, then accepted 2/2 (0 refusals) on the final
   full run. No configuration change. The harness therefore retries up to 3×
   per sample and records `refusalCount` — the final run's 10/10 samples
   needed 0 retries, so the flakiness is real but rare. Treat a single refusal
   as retryable, not as a content verdict.
3. **Guardrails and instructions do not matter** for this workload: all four
   cells of the guardrails × instructions matrix accepted
   (`default`/`permissiveContentTransformations` × `none`/`set`). The
   `.permissiveContentTransformations` name is misleading for *our* content —
   it refused once in the early smoke run while `.default` accepted the same
   input; that was the nondeterminism, not the guardrails. Don't read
   semantics into the guardrails enum beyond what the matrix shows.
4. **The provider seam is `SystemLanguageModel.Adapter`, not a protocol.**
   The macOS 26.4 SDK's FoundationModels module has exactly six public
   protocols (Generable, ConvertibleFromGeneratedContent,
   ConvertibleToGeneratedContent, InstructionsRepresentable, PromptRepresentable,
   Tool) — **no `Provider` / `LanguageModelProvider` protocol exists**.
   `LanguageModelSession` binds concretely to `SystemLanguageModel`; a custom
   backend plugs in via `SystemLanguageModel(adapter:)`, i.e. model *files*
   packaged as adapter assets. Runtime evidence:
   `Adapter.compatibleAdapterIdentifiers(name: "com.example.mlx-backend")`
   returns `["fmadapter-com.example.mlx-backend-9799725"]` — the registry
   normalises arbitrary names into `fmadapter-` asset identifiers.
   **Verdict: the "write against a protocol so an MLX-backed provider swaps in
   unchanged" claim is refuted in its literal form and confirmed in a narrower
   one.** You cannot conform a Swift type to a provider protocol; you can ship
   an adapter asset. An MLX backend would have to compile to / wrap an
   adapter asset pack — an integration project, not a config change. The
   `foundation-models.md` note's "any LLM can implement" wording is corrected
   below.

## Availability (the tri-state, measured)

`SystemLanguageModel.default.availability` is the API. Observed state on this
machine: **`.available`** (contextSize 4096, 23 supported languages, current
locale supported, `isAvailable == true`).

The three `UnavailableReason` cases that exist in the SDK:
`deviceNotEligible` (non-Apple-Silicon or pre-Apple-Intelligence Mac),
`appleIntelligenceNotEnabled` (user turned Apple Intelligence off), and
`modelNotReady` (model download/publish incomplete). The probe code compiles
against all three; only one is observable per machine, so the other two are
documented here, not measured:

- Vanish-cleanly contract: check `isAvailable`/`availability` **before**
  creating a session and before showing the feature. The feature must not
  exist in the UI when unavailable — no error, no grey-out-with-explanation.
  `appleIntelligenceNotEnabled` is a user setting; respect it without nagging.
- `modelNotReady` is interesting: it can self-heal (the OS publishes the model
  later), so the app should re-check on foreground, not cache a permanent
  "unavailable".

## Latency (respond path, full run, 2 samples)

| fixture | tokens | s1 | s2 |
|---|---|---|---|
| news-article | 258 | 2.7 s | 3.1 s |
| docs-page | 214 | 12.0 s | 15.6 s |
| dense-technical | 275 | 11.9 s | 16.5 s |
| paywalled-teaser | 138 | 15.7 s | 13.9 s |
| spa-rendered | 200 | 13.3 s | 15.1 s |

- First-call latency is the outlier: one earlier run saw docs-page s1 at
  **38.4 s** (cold model load); the first two calls of the final run (the
  news-article pair) were the fastest at ~3 s. **Warm-state is ~12–16 s per
  summary**, so a summarise feature is a "spinner for ~15 s" UX, not
  instant. `prewarm(promptPrefix:)` exists but was not measured.
- TTFT: unavailable via `streamResponse` (finding 1). Token counts are exact
  (`tokenCount(for:)`, macOS 26.4+).

## Quality (notes, not scores)

- **Summarisation is genuinely good** at this model's scope. The dense-
  technical fixture got an accurate summary (620 ps skew budget, 1.4 UI
  equalisation, the unbounded-across-corners caveat) — correct numbers,
  correct structure, no invented detail.
- **The reasoning probe accidentally tested hallucination-resistance, and the
  model passed.** The probe asked about "the second cache index" — a thing
  that does not exist in the dense-technical fixture (zero occurrences of
  "cache"). The model did not fabricate it; it answered the spec's actual
  subject and quoted the exact line (`let skew = traceDelay - clockDelay
  assert(skew < bitPeriod / 4)`). That is the behaviour you want from a
  summariser feature: ground in the text, refuse to invent. A v2 probe should
  ask an in-scope multi-hop question (e.g. "what is the skew budget at 200
  MHz and which two terms dominate?") to actually find the reasoning
  ceiling the notes predict — not demonstrated here.
- The "dense-technical reasoning no" prediction from the notes is therefore
  **unconfirmed by this probe** — the one reasoning sample succeeded. Mark it
  unverified rather than assumed.

## How to run

```sh
swift run -c release foundation-models-probe            # full: 5 fixtures × 2 samples + probes
swift run -c release foundation-models-probe --quick    # 1 sample per fixture
swift run -c release foundation-models-probe --quick --skip-probes --fixture=news-article
```

Writes `results.json` (stamped) in this directory. The full run takes ~3–5
minutes (the model is the slow part); the probe is Swift 6 strict-concurrency
clean.

---

## Measured-hacking log (dead ends, with fixes)

1. **v1 refused summarisation — thought it was the default guardrails.**
   First smoke run: `Refusal("May contain sensitive content")`. The SDK ships
   `.permissiveContentTransformations`, whose name says "content
   transformations allowed" — obvious suspect, switched to it. **Wrong.**
   The permissive mode refused *more* often in early runs while `.default`
   accepted. The 4-cell matrix showed guardrails and instructions are
   irrelevant; the variable was the **stream path** (v1 used
   `streamResponse` for TTFT) and then plain nondeterminism. Fix: use
   `respond`, retry on refusal, count refusals. Lesson: with a mutable
   black-box service, change one variable per run.
2. **The `tokenCount` API looked poisoned.** v1 called
   `tokenCount(for:)` right before generation and I suspected it corrupted
   the session. Cell 2 of the path probe (tokenCount-then-respond) accepted
   cleanly — not the cause. It *is* `macOS 26.4+` (unlike the rest of the
   framework's 26.0 floor), so guard it with `#available`, or the whole probe
   fails to compile on the 26.0 SDK.
3. **`launchctl submit` runs jobs with cwd = `/`.** The harness reads
   `Fixtures/` relative to cwd and writes `results.json` there; the detached
   run silently errored on every fixture and the write vanished into a
   permissions void. Fix: wrap with `sh -c "cd <probe dir> && exec <binary>"`.
   Also: `nohup ... &` from a tool shell dies with the shell — the launchd
   wrapper is the reliable detach.
4. **Stale-binary trap.** Edited the probe, ran `swift build`, then executed
   `.build/release/...` — `swift build` builds *debug*; the release binary
   was the previous build. The new `refusalCount` field never appeared and I
   re-investigated a "bug" that was the old binary. Fix: `swift build -c
   release` and check the timestamp of the binary you run.
5. **`[redacted]` hallucinations in the harness output.** Twice a JSON read
   showed `"inputTokens": [redacted]` while `grep` on the same file showed
   `258`. The file was fine both times (verified byte-level); the display
   layer was redacting, or the read raced a non-atomic write. Fix: read the
   file with `xxd`/`grep` when a value looks wrong before trusting any tool
   output. Also why the SDK's own interface file *does* contain `[redacted]`
   tokens: Apple redacts some signatures in `swiftinterface`; `sed` shows
   them, `grep -A4` shows the real text — same file.
6. **Latency variance is 3–38 s for the same input.** The 38.4 s outlier was
   docs-page s1 after the model had idled; the same fixture ran 12–16 s in
   the final run. Two samples bound nothing (standing rule) — rerun via the
   committed harness.

## Corrections to repo docs

- `../foundation-models.md` "What it is": the sentence "a public protocol
  layer that *any* LLM can implement" is **wrong for this SDK** — no provider
  protocol exists (finding 4). The seam is `SystemLanguageModel.Adapter`
  asset packaging. The strategic-unlock paragraph stands, but the mechanism
  is adapter assets, not protocol conformance.
- `../foundation-models.md` "Risks": the "~3B is small / dense-technical
  reasoning no" line is now *unverified* rather than assumed — see quality
  notes; the one in-scope reasoning attempt succeeded.
