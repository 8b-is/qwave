# swift-metrics

| Fact | Value |
|---|---|
| **Repo** | https://github.com/apple/swift-metrics |
| **Latest version** | 2.5.x (2026-08, re-verify) |
| **License** | Apache-2.0 (Swift license) |
| **Platforms** | All Swift platforms |
| **Apple Silicon status** | ✅ Native |

## What it is

Metrics API (counters, gauges, timers) with swappable backends.

## Why it matters for Qwave

- Only valuable once Qwave ships telemetry (opt-in); currently there is
      nothing to export.

## Apple Silicon notes

- Native.

## Adoption sketch

- Adopt together with a telemetry feature flag; not before.

## Risks

- Instrumentation noise without a consumer.

## Verdict: Assess — pair with opt-in telemetry
