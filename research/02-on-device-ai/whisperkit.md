# WhisperKit (`argmaxinc/WhisperKit`)

| | |
|---|---|
| **Repo** | https://github.com/argmaxinc/WhisperKit |
| **Version** | **1.1.0** |
| **License** | MIT |
| **Platforms** | macOS, iOS |
| **Apple Silicon** | Core ML-backed; runs on the Neural Engine |
| **Verified** | 2026-08-12 |

---

## What it is

On-device speech-to-text built on OpenAI's Whisper models, packaged for Apple platforms via
Core ML. It is a well-engineered package — the 1.1.0 release cut peak memory by more than 70%
for three-hour audio inputs through incremental file loading, and sped up TTS models by roughly
40% end-to-end. That is serious optimisation work, not a thin wrapper.

## Why it matters for Qwave

**It does not.** This note exists so the question is answered once.

Qwave is a browser. The plausible speech features are:

| Feature | Why not |
|---------|---------|
| Voice search in the omnibox | macOS already provides system dictation, in every text field, including `OmniboxField`. Users have it, it works, it needs no code. |
| Media transcription | Web pages provide their own captions. A browser transcribing arbitrary page audio is a surprising and privacy-adjacent behaviour, not a feature. |
| Accessibility | VoiceOver is text-to-speech, the opposite direction, and is a system service. |

Every use case is either already solved by the OS or is not something a browser should do.

The cost side is unambiguous: model downloads, audio pipeline, microphone entitlements — and
that last one matters more than it looks. Adding microphone access to `Qwave.entitlements`
weakens the sovereignty claim for a feature nobody asked for. A privacy-first browser
requesting the microphone is a headline, not a checkbox.

## Apple Silicon notes

Core ML execution targets the Neural Engine, where Whisper runs efficiently — this is a genuine
strength of the package. It is simply irrelevant here, and it competes for the same accelerators
any [Foundation Models](foundation-models.md) feature would use.

## Adoption sketch

None. If speech input is ever genuinely wanted, use the system frameworks — `SFSpeechRecognizer`
or built-in dictation — which require no model download, no new dependency, and carry the
platform's own privacy affordances and user consent UI.

## Risks

Not applicable — the recommendation is not to adopt. The risk being managed is **scope creep**:
an impressive package in an adjacent domain is the easiest kind of dependency to add for no
reason.

## Verdict

🔴 **Hold.**

Excellent package, wrong product. Recorded here so that "should Qwave do voice?" resolves in one
minute rather than one sprint.

Should the answer ever change, revisit **system dictation first** — it covers the only credible
use case at zero dependency cost and without touching the entitlements file.
