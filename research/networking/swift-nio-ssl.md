# swift-nio-ssl

| Fact | Value |
|---|---|
| **Repo** | https://github.com/apple/swift-nio-ssl |
| **Latest version** | 2.3x (2026-08, re-verify) |
| **License** | Apache-2.0 |
| **Platforms** | All Swift platforms |
| **Apple Silicon status** | ✅ Native (BoringSSL vendored) |

## What it is

TLS for SwiftNIO via a vendored BoringSSL.

## Why it matters for Qwave

- Irrelevant without NIO; Qwave's TLS is URLSession/Network.framework
      (system root store, system routing).

## Apple Silicon notes

- Vendored BoringSSL means own-pace security patches — a cost, not a
      feature, for a browser that values system trust.

## Adoption sketch

- Skip.

## Risks

- Redundant crypto stack; patch latency.

## Verdict: Hold
