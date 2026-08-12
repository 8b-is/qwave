# CryptoSwift

| Fact | Value |
|---|---|
| **Repo** | https://github.com/krzyzanowskim/CryptoSwift |
| **Latest version** | 1.8.x (2026-08, re-verify) |
| **License** | AGPL-3.0 |
| **Platforms** | All Swift platforms |
| **Apple Silicon status** | ✅ Works (pure Swift) |

## What it is

The community's pure-Swift crypto toolbox (hashes, AES, ChaCha, …).

## Why it matters for Qwave

- **AGPL + unverified constant-time behaviour** make it a poor fit for
      a security product; Qwave's needs are covered by CryptoKit + the
      audited PostQuantum module.

## Apple Silicon notes

- Pure Swift but slow (no hardware acceleration).

## Adoption sketch

- Do not adopt.

## Risks

- License (AGPL); side-channel hardening unclear.

## Verdict: Hold
