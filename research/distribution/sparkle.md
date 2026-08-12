# Sparkle

| Fact | Value |
|---|---|
| **Repo** | https://github.com/sparkle-project/Sparkle |
| **Latest version** | 2.9.5 (verified 2026-08-12) |
| **License** | MIT |
| **Platforms** | macOS |
| **Apple Silicon status** | ✅ Native (framework + xpc) |

## What it is

The de-facto macOS auto-update framework: appcast feeds, delta
    updates, and signed update verification.

## Why it matters for Qwave

- **Gates Stage B and the VPN**: a network extension needs a signed,
      notarised host app. Sparkle is the update channel for exactly that
      signed app — adopting it is part of the signing work, not a separate
      project.
    - Unsigned ZIP distribution (current v0.2.0) cannot use Sparkle — so this
      is scheduled with, not before, code signing.

## Apple Silicon notes

- v2 is arm64-native; `SUEnableInstallerLauncherService` + XPC.

## Adoption sketch

- After signing: embed Sparkle, point appcast at GitHub Releases
      (generate_appcast), require EdDSA signatures.

## Risks

- Security-sensitive dependency — treat as trust anchor. Delta updates
      require careful release tooling.

## Verdict: Adopt — gated on code signing
