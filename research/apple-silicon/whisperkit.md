# WhisperKit

| Fact | Value |
|---|---|
| **Repo** | https://github.com/argmaxinc/WhisperKit |
| **Latest version** | 0.9.x (2026-08, re-verify) |
| **License** | MIT |
| **Platforms** | macOS / iOS |
| **Apple Silicon status** | ✅ Native (Core ML + Swift) |

## What it is

A Swift wrapper around OpenAI's Whisper speech-to-text, running
    fully on-device via Core ML with Swift-only inference pipeline.

## Why it matters for Qwave

- On-device dictation for the omnibox would be a genuine differentiator
      (Safari has none).
    - Runs on the Neural Engine; nearly free in energy terms versus cloud STT.

## Apple Silicon notes

- `computeUnits: .cpuAndNeuralEngine` is the right setting on M-series;
      pure GPU runs measurably hotter.

## Adoption sketch

- Optional `QwaveDictation` feature behind a flag; models (~150 MB)
      downloaded on demand, never bundled.

## Risks

- Large model weights; version churn; Core ML model compilation cost on
      first run.
    - Voice data handling needs a privacy story (process locally, discard).

## Verdict: Hold — no browser feature depends on speech today; revisit with dictation
