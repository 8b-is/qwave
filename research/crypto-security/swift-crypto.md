# swift-crypto

| Fact | Value |
|---|---|
| **Repo** | https://github.com/apple/swift-crypto |
| **Latest version** | 3.x (2026-08, re-verify) |
| **License** | Apache-2.0 (Swift license) |
| **Platforms** | All Swift platforms |
| **Apple Silicon status** | ✅ Native |

## What it is

Apple's Swift re-implementation of the CryptoKit API on top of
    BoringSSL — same surface, portable.

## Why it matters for Qwave

- Qwave's PostQuantum module is hand-rolled (Keccak, ML-KEM-768,
      McEliece) — none of that exists in swift-crypto.
    - Marginal: swift-crypto adds curve/EC primitives that CryptoKit already
      provides on macOS.

## Apple Silicon notes

- On macOS, CryptoKit's Secure Enclave / hardware paths are the
      stronger choice; swift-crypto is pure software.

## Adoption sketch

- Skip — CryptoKit covers the classic-crypto needs.

## Risks

- A second TLS/crypto stack to audit; no feature gap it closes today.

## Verdict: Hold
