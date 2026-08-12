# Pulse

| Fact | Value |
|---|---|
| **Repo** | https://github.com/kean/Pulse |
| **Latest version** | 5.2.3 (verified 2026-08-12) |
| **License** | MIT |
| **Platforms** | macOS / iOS |
| **Apple Silicon status** | ✅ Native |

## What it is

A network-logger + debug console for URLSession traffic, with a
    beautiful macOS console UI.

## Why it matters for Qwave

- Excellent for developing `VPNKit` (Mullvad API traffic) and the
      blocklist updater; helps verify *which route* requests actually take —
      directly relevant to the VPN routing guarantees.

## Apple Silicon notes

- Native; debug-only integration keeps it out of release builds.

## Adoption sketch

- Add behind `#if DEBUG` for VPN/API development.

## Risks

- Must never leak into Release (captured payloads = sensitive).

## Verdict: Trial (debug-only)
