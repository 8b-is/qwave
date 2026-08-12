# 02 · On-Device AI & ML

| Package | Version | Verdict | Qwave relevance |
|---------|---------|---------|-----------------|
| [MLX Swift](mlx-swift.md) | 0.31.6 | 🔵 Trial | Optional local inference module |
| [Foundation Models](foundation-models.md) | macOS 26+ platform API | 🔵 Trial | Zero-download summarisation |
| [mlx-swift-examples](mlx-swift-examples.md) | 2.29.1 | 🟡 Assess | Reference code, not a dependency |
| [swift-transformers](swift-transformers.md) | 1.3.3 | 🟡 Assess | Tokenisation + Hub model fetch |
| [WhisperKit](whisperkit.md) | 1.1.0 | 🔴 Hold | Out of scope |

---

## The sovereignty argument

A browser that ships a cloud AI feature has undone its own privacy story. A browser that runs
the same feature **entirely on-device**, on hardware the user already owns, has strengthened it.
That is the only reason this category belongs in a browser research folder at all.

The M5 generation makes it affordable: a Neural Accelerator in every GPU core, and Apple's own
measurements showing **3.3×–4.06× faster time-to-first-token** versus M4 across Qwen 1.7B–14B
and GPT-OSS-20B.

## The two paths

|  | Foundation Models | MLX Swift |
|--|-------------------|-----------|
| Model | Apple's ~3B on-device model | Any model you can convert |
| Download | None — part of the OS | 1–20 GB, you ship or fetch it |
| Floor | macOS 26 + Apple Intelligence hardware | macOS 26.2+ for M5 Neural Accelerators |
| Control | Apple's model, Apple's updates | Total |
| Effort | Three lines of Swift | A real subsystem |

**Take Foundation Models first.** It is the option with no download, no model management, no
storage cost, and no meaningful maintenance surface. MLX becomes interesting only if a specific
capability is missing from Apple's model — and WWDC26's provider protocol means MLX-backed
models can now plug in behind the *same* `LanguageModelSession` API, so choosing Foundation
Models first does not foreclose MLX later.

## The hard constraints

Any AI feature in Qwave must satisfy all four, or it does not ship:

1. **Optional.** Never a launch dependency. The browser must be fully functional with the
   entire module absent.
2. **Local.** No network egress. That is the whole premise.
3. **Energy-aware.** Inference is the single most power-hungry thing a browser could do. It must
   consult `EnergyGovernor` and must not run under memory or thermal pressure.
4. **Explicit.** User-invoked, per-invocation. Never speculative, never background, never
   "helpfully" summarising pages nobody asked about.

Constraint 3 deserves emphasis. Qwave's entire differentiation is the `TabHibernator` /
`EnergyGovernor` pairing — a browser that *saves* battery. Bolting on an unmetered inference
engine would contradict the product.
