# MLX Swift

| Fact | Value |
|---|---|
| **Repo** | https://github.com/ml-explore/mlx-swift |
| **Latest version** | 0.31.6 (verified 2026-08-12) |
| **License** | MIT |
| **Platforms** | macOS / iOS / visionOS, arm64-first (AMX/GPU via MLX C core) |
| **Apple Silicon status** | ✅ Native (Apple GPU, unified memory) |

## What it is

Apple's MLX array framework with a Swift binding: NumPy-style arrays,
    automatic differentiation, and a lazy graph engine that runs on the Apple
    GPU and AMX co-processors through a unified-memory C++ core.

## Why it matters for Qwave

- **EnergyGovernor / HibernationController**: MLX is the only framework
      whose memory model plays nicely with Qwave's hibernation philosophy —
      unified memory means model tensors page out exactly like tab state.
    - **On-device phishing/heuristics**: the Shields pipeline could classify
      page content without shipping it off-device, keeping the "sovereign"
      promise.
    - **No cgo/FFI mess**: unlike llama.cpp bindings, MLX Swift is a
      first-party Swift API.

## Apple Silicon notes

- arm64-only; a universal Qwave build must gate it behind
      `#if arch(arm64)` and feature flags.
    - Memory is allocated from the shared pool — a runaway model competes
      with WebKit content processes; cap with `mlx.enableMemoryLimit()`.

## Adoption sketch

- Add as an optional `QwaveML` target behind a feature flag.
    - First use case: offline page-language detection for Shields (tiny model,
      no network). Not a core dependency.

## Risks

- Fast-moving API (0.x cadence); pins must be exact.
    - x86_64 unsupported — kills Intel test CI coverage for anything touching it.
    - Adds ~200 MB to the app when models are bundled.

## Verdict: Trial
