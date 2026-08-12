# Metal 4

| | |
|---|---|
| **Source** | Apple platform framework |
| **Introduced** | WWDC25 — session 205, "Discover Metal 4" |
| **Availability** | macOS 26+ / iOS 26+ |
| **License** | Apple SDK |
| **Apple Silicon** | **Required.** Metal 4 is Apple Silicon-only by design. |
| **Verified** | 2026-08-12 |

---

## What it is

A ground-up redesign of Metal's core API, built for Apple Silicon exclusively — Intel Macs are
left on Metal 3. The redesign covers command encoding, resource binding, and synchronisation,
but the headline is the **convergence of machine learning and graphics into a single GPU
timeline**.

Three additions matter:

- **`MTLTensor`** — multi-dimensional data containers for ML, present both as an API resource
  type and as a type in the Metal Shading Language.
- **`MTL4MachineLearningCommandEncoder`** — runs entire networks on the GPU timeline, scheduled
  alongside ordinary draws and dispatches rather than in a separate pass.
- **Shader ML** — embeds ML operations inside your own shaders. Neural material evaluation,
  from tensor initialisation through inference to shading, collapses into a single shader
  dispatch.

Quantised data type support (4- and 8-bit integers) arrived in a macOS/iOS 26 update, with the
supported set widening in macOS/iOS 27.

## Why it matters for Qwave

**Indirectly, and that is the whole point of this note.**

Qwave does not issue GPU commands. WebKit does — for compositing, rasterisation, video, WebGL,
and WebGPU. Adding a second Metal consumer to the process tree means competing with the
renderer for the device that renders your product.

Metal 4 matters to Qwave in three secondary ways:

1. **It sets the platform's Apple Silicon-only line.** Metal 4 leaving Intel behind confirms
   the direction Qwave has already taken, and strengthens the case for eventually raising the
   deployment target rather than defending macOS 14 indefinitely.
2. **WebGPU rides on it.** Web content increasingly reaches the GPU through WebGPU, and WebKit's
   implementation sits on Metal. Pages doing heavy GPU work are a *battery* and *thermal* event
   — which makes it an `EnergyGovernor` concern, not a graphics-programming one.
3. **It is the substrate under MLX.** Any [MLX Swift](../02-on-device-ai/mlx-swift.md) work
   ultimately lands here. Understanding tensors and the ML command encoder explains the
   performance characteristics of the AI features in category 02.

### The one direct opportunity

**GPU utilisation as an energy signal.** `EnergyGovernor` decides when to hibernate tabs.
It reasons about memory pressure today. A tab running a sustained WebGL or WebGPU workload is
draining battery in a way memory pressure will never reveal.

Sampling `MTLDevice` counters and per-process GPU statistics is **observation, not submission** —
it costs no GPU time and it feeds directly into the decision `TabHibernator` already makes. This
is the only Metal-adjacent work in this repository that plays to Qwave's actual
differentiation.

## Apple Silicon notes

Metal 4 exists because of the unified memory architecture and the per-core Neural Accelerators
introduced with M5. Tensors are cheap to move between ML and graphics stages precisely because
there is nothing to move — CPU, GPU, and Neural Engine address the same memory.

For a browser, the practical consequence is that **GPU memory pressure and system memory
pressure are the same pressure**. A page allocating large WebGPU buffers is competing with
`WKWebView` content processes and with anything MLX might be holding. That is a strong argument
for `EnergyGovernor` learning about GPU state.

## Adoption sketch

Not for rendering. For observation:

```swift
// BrowserCore/EnergyGovernor.swift — read, never submit
@available(macOS 26.0, *)
extension EnergyGovernor {
    var gpuPressure: GPUPressure {
        guard let device = MTLCreateSystemDefaultDevice() else { return .unknown }
        let used = device.currentAllocatedSize
        let budget = device.recommendedMaxWorkingSetSize
        return GPUPressure(ratio: Double(used) / Double(budget))
    }
}
```

Feed that into the existing hibernation heuristic beside memory pressure. `EnergyGovernorTests`
already exists as the place to prove the policy behaves.

## Risks

- **Competing with the renderer.** Any GPU work Qwave submits delays WebKit's. In a browser,
  that is a frame-rate regression the user attributes to page performance.
- **macOS 26 floor**, three majors above Qwave's target.
- **Scope creep.** "We could use Metal" is a very easy sentence to say about an Apple Silicon
  app. The answer for a browser shell is almost always no.
- **Counters are advisory.** `currentAllocatedSize` reflects the current process's Metal
  allocations, not WebKit's separate content processes. Treat GPU pressure as one weak signal,
  not a precise measurement, and validate it against real battery behaviour before letting it
  drive hibernation.

## Verdict

🟡 **Assess — understand it, do not render with it.**

Metal 4 is genuinely important to the platform and genuinely not Qwave's job. The one idea worth
extracting is **GPU pressure as an `EnergyGovernor` input**, and that is a small, self-contained,
testable change gated on macOS 26 — with the caveat above about what the counters actually
measure.

Everything else in Metal 4 reaches Qwave through WebKit and MLX, which is exactly how it should.

---

**References:**
[Discover Metal 4 — WWDC25 session 205](https://developer.apple.com/videos/play/wwdc2025/205/) ·
[Optimize custom machine learning operations with Metal tensors — WWDC26 session 330](https://developer.apple.com/videos/play/wwdc2026/330/)
