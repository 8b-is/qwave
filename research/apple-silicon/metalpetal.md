# MetalPetal

| Fact | Value |
|---|---|
| **Repo** | https://github.com/MetalPetal/MetalPetal |
| **Latest version** | 1.25.x (2026-08, re-verify) |
| **License** | MIT |
| **Platforms** | macOS / iOS (Metal) |
| **Apple Silicon status** | ✅ Native (Metal compute) |

## What it is

A GPU-accelerated image/video processing framework built on Metal
    compute kernels, with Core Image interop.

## Why it matters for Qwave

- Nothing in the current Qwave pipeline (WKWebView rendering) needs it.
    - Would matter for screenshot-driven tab previews at scale, or a future
      tab-thumbnail pipeline.

## Apple Silicon notes

- Metal shaders compile per-device; arm64 family sharing keeps builds small.

## Adoption sketch

- Skip until tab previews become a real feature.

## Risks

- GPU contention with WebKit's compositor; risk of regressing the very
      battery claims Qwave makes.

## Verdict: Hold
