# Alloy (`s1ddok/Alloy`)

| | |
|---|---|
| **Repo** | https://github.com/s1ddok/Alloy |
| **Version** | **0.18.2** |
| **License** | MIT |
| **Platforms** | macOS, iOS |
| **Apple Silicon** | Metal-native; no architecture-specific concerns |
| **Verified** | 2026-08-12 |

---

## What it is

A thin ergonomics layer over the Metal API. Alloy removes the boilerplate that makes small
Metal tasks disproportionately verbose: command buffer and encoder management, texture
descriptor construction, threadgroup size computation, and a library of ready-made compute
encoders for common operations.

It does not abstract Metal away. You are still writing Metal — with materially less ceremony.

## Why it matters for Qwave

Conditionally, and the condition is not currently met.

As established in [Metal 4](metal-4.md), **WebKit owns the GPU** in this application. Alloy is
a convenience layer over an API Qwave has no current reason to call, which makes it a
convenience over nothing.

The one scenario where it becomes relevant: **a visual tab switcher**. `TabHibernator` captures
state when unloading a tab. Rendering a grid of live tab previews means snapshotting, downscaling,
and compositing many textures — which is real GPU work, and exactly the shape Alloy is good at.

Even then, the honest comparison is not Alloy versus raw Metal. It is:

| Approach | Cost | Fit |
|----------|------|-----|
| `NSImage` + `CGImage` downscale | Zero dependencies | Fine for a handful of thumbnails |
| **Core Image** | Zero dependencies, GPU-backed, already optimised on Apple Silicon | The right answer for image pipelines |
| **Core Animation** | Zero dependencies | The right answer if the compositing is the point |
| Alloy | One dependency, custom kernels | Only if the above genuinely fall short |

Core Image already runs on the GPU, is Apple-maintained, ships with the OS, and is tuned for
Apple Silicon. For thumbnail work it is very hard to lose to it.

## Apple Silicon notes

No Apple Silicon-specific behaviour — it is a wrapper, and it inherits whatever Metal does. Its
threadgroup-sizing helpers query the device rather than hardcoding, which is correct given the
range of GPU core counts across M1 through M5 Max, but that is table stakes rather than a
differentiator.

Alloy predates Metal 4. Whether it exposes `MTLTensor`, `MTL4MachineLearningCommandEncoder`, or
the Metal 4 command structure would need checking before use on a macOS 26+ path.

## Adoption sketch

```swift
.package(url: "https://github.com/s1ddok/Alloy", from: "0.18.2")
```

```swift
// Hypothetical: downscaling a tab snapshot for a visual switcher
let context = try MTLContext()
let resize = try context.textureCopy(scaling: .aspectFill)
try context.scheduleAndWait { buffer in
    resize.encode(sourceTexture: snapshot, destinationTexture: thumbnail, in: buffer)
}
```

Before writing this, write the Core Image version. It is shorter, has no dependency, and is
very likely fast enough.

## Risks

- **Solves a problem Qwave does not have.** No current GPU workload.
- **Pre-1.0** at 0.18.x, with a slower cadence than the Apple-maintained packages here.
- **Metal 4 currency unverified.** A wrapper over a redesigned API needs to have kept up.
- **Competes with the renderer.** Any GPU work Qwave submits contends with WebKit's.

## Verdict

🟡 **Assess — reasonable package, no current use case.**

If Qwave ever ships a visual tab switcher and Core Image proves inadequate, Alloy is a sane way
to write the kernels without the full Metal ceremony. That is two conditionals away.

The generalisable point: for image work on Apple Silicon, reach for **Core Image** first. It is
GPU-backed, Apple-tuned, dependency-free, and it wins on every axis a browser shell cares about.
