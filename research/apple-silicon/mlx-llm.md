# MLX-LLM

| Fact | Value |
|---|---|
| **Repo** | https://github.com/ml-explore/mlx-llm |
| **Latest version** | 0.2.x (2026-08, re-verify) |
| **License** | MIT |
| **Platforms** | macOS (CLI) / iOS |
| **Apple Silicon status** | ✅ Native |

## What it is

Applications (CLI + libraries) for running LLMs on Apple Silicon with
    MLX — the reference stack for local inference.

## Why it matters for Qwave

- A local "page summariser" sidebar is the natural Stage-C feature; MLX-LLM
      is the proven way to host it.
    - Not a dependency for the browser core — a companion service pattern.

## Apple Silicon notes

- M5-class NPUs will make 7B-class models viable at interactive speed;
      M1/M2 need quantised 1-3B models.

## Adoption sketch

- Companion app or XPC service; never linked into the browser process
      (memory isolation).

## Risks

- Licensing/distribution of model weights is a product decision, not a
      technical one.
    - Large memory footprint; conflicts with hibernation budgets.

## Verdict: Hold — evaluate only when a local-AI feature is scoped
