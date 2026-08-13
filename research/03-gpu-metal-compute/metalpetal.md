# MetalPetal (`MetalPetal/MetalPetal`)

| | |
|---|---|
| **Repo** | https://github.com/MetalPetal/MetalPetal |
| **Version** | **1.25.2** |
| **License** | MIT |
| **Platforms** | macOS, iOS |
| **Apple Silicon** | Metal-native |
| **Verified** | 2026-08-12 |

---

## What it is

A GPU-accelerated image and video processing framework built on Metal. MetalPetal provides a
render-graph model — you compose filter nodes into a graph and the framework schedules, fuses,
and executes it efficiently. It is mature, actively maintained, and genuinely good at what it
does: real-time video filter chains, camera pipelines, and photo editing.

## Why it matters for Qwave

**It does not.** Recorded so the question closes.

MetalPetal solves image and video *processing* — applying filter chains to pixel data. A browser
does not process images; it **displays** them, and WebKit handles that entirely: decode,
colour management, compositing, and video playback all live inside WebKit's own processes.

The one place Qwave touches pixels at all is tab snapshots for `TabHibernator`. That is a
downscale, and the answer there is Core Image or `CGImage` — see [Alloy](alloy.md) for the
comparison. Pulling in a video processing framework for a thumbnail resize is a large dependency
for a two-line problem.

There is also a resource-contention argument, which is the same one that runs through this whole
category. MetalPetal's render graph is designed to saturate the GPU. In a browser, saturating the
GPU means starving the renderer — the user sees dropped frames on the page and blames page
performance.

## Apple Silicon notes

Well-optimised for Apple Silicon; the unified memory architecture suits its texture-heavy
pipeline. The 1.25.2 release added an `autoreleasepool` in the async video composition request
handler to address autorelease frequency — the kind of detail that signals a maintainer who
understands the platform.

Correct engineering, irrelevant domain.

## Adoption sketch

None.

If a future feature genuinely needs image processing — a reader-mode screenshot exporter, say —
evaluate **Core Image** first. It is GPU-backed, Apple-maintained, ships with the OS, has no
dependency cost, and covers the filter vocabulary a browser could plausibly want.

## Risks

Not applicable. The risk being managed here is the same one as
[WhisperKit](../02-on-device-ai/whisperkit.md): a high-quality package in an adjacent domain is
the easiest kind of dependency to add for no reason.

## Verdict

🔴 **Hold.**

Excellent framework, wrong application category. Qwave displays web content; it does not process
video.
