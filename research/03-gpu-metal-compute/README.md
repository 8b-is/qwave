# 03 · GPU, Metal & Compute

| Package | Version | Verdict | Qwave relevance |
|---------|---------|---------|-----------------|
| [Metal 4](metal-4.md) | macOS 26+ platform API | 🟡 Assess | Understand it; WebKit owns the GPU |
| [Alloy](alloy.md) | 0.18.2 | 🟡 Assess | Only if custom compute ever appears |
| [MetalPetal](metalpetal.md) | 1.25.2 | 🔴 Hold | Wrong domain |

---

## The honest framing

**WebKit owns the GPU in this application.** Compositing, rasterisation, video decode, WebGL,
and WebGPU all run inside WebKit's own processes using its own Metal usage. Qwave is the shell
around that, and a shell that starts issuing its own GPU work is competing with the renderer for
the device it depends on.

So this category is mostly **Assess** and **Hold**, and that is the correct outcome — not a gap.
It is documented because "we're on Apple Silicon, we should use Metal" is an intuition that
recurs, and it deserves a written answer.

## Where GPU work would actually be legitimate

Three narrow cases, in rough order of plausibility:

1. **Tab thumbnail generation.** `TabHibernator` captures state when unloading a tab. If Qwave
   ever renders a visual tab-switcher, downscaling and compositing snapshots is real GPU work —
   though `Core Image` and `Core Animation` cover it with far less machinery.
2. **On-device model inference.** Covered in [02 · On-Device AI](../02-on-device-ai/). MLX
   already sits on Metal; you would not hand-write those kernels.
3. **Reading the GPU as an energy signal.** Not issuing work — *observing* it.
   `EnergyGovernor` currently maps three inputs to a tier: thermal state, low-power mode, and
   window occlusion. GPU utilisation is a legitimate fourth, it costs no GPU time to sample, and
   the governor's pure-function design makes adding it a small, testable change.

Case 3 is the interesting one, and it is the only one that plays to Qwave's actual
differentiation.

## What is genuinely new in Metal 4

Worth knowing even if Qwave never issues a draw call, because it explains the platform's
direction:

- **Apple Silicon only.** Metal 4 leaves Intel Macs behind entirely — the same line Qwave
  already draws.
- **`MTLTensor`** — multi-dimensional tensors as a first-class API and shading-language type.
- **`MTL4MachineLearningCommandEncoder`** — whole networks on the GPU timeline, interleaved with
  draws and dispatches.
- **Shader ML** — ML operations embedded inside your own shaders, so neural material evaluation
  collapses into a single dispatch.
- **Quantised types** — 4- and 8-bit integer support landed in a macOS/iOS 26 update, with more
  data types extending in macOS/iOS 27.

The direction of travel is unambiguous: ML and graphics are converging into one timeline on
Apple Silicon. That matters to Qwave indirectly, through WebKit's WebGPU implementation and
through MLX — not through code Qwave writes.
