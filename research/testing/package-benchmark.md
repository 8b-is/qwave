# package-benchmark

| Fact | Value |
|---|---|
| **Repo** | https://github.com/ordo-one/package-benchmark |
| **Latest version** | 1.3x (2026-08, re-verify) |
| **License** | Apache-2.0 |
| **Platforms** | macOS / Linux |
| **Apple Silicon status** | ✅ Native |

## What it is

SPM-integrated benchmarks with statistics (throughput, allocation
    counts) via JMH-style harnesses.

## Why it matters for Qwave

- Could measure the uBO compile pipeline and crypto hot paths
      (McEliece decaps in debug is ~35 s — worth tracking in release).
    - **Cannot** measure hibernation's reclaimed memory: that lives in
      WebKit's out-of-process content processes, outside the harness.

## Apple Silicon notes

- Uses `sudo` for page-fault metrics on macOS — a CI annoyance.

## Adoption sketch

- Add a `Benchmarks` executable target for PostQuantum and Shields.

## Risks

- Benchmark drift is noise-prone; keep thresholds loose.

## Verdict: Assess — useful, but not for the headline energy claim
