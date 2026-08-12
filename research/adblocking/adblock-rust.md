# adblock-rust

| Fact | Value |
|---|---|
| **Repo** | https://github.com/brave/adblock-rust |
| **Latest version** | 0.13.2 (verified 2026-08-12) |
| **License** | MPL-2.0 |
| **Platforms** | macOS / iOS / Linux / Windows (Rust core + C FFI) |
| **Apple Silicon status** | ✅ Works (Rust FFI) |

## What it is

Brave's ad-blocking engine in Rust — the production filter pipeline
    behind Brave Browser.

## Why it matters for Qwave

- Qwave already compiles uBO/EasyList syntax to WKContentRuleList in
      `Shields.UBORuleListCompiler`; adblock-rust's parser is stronger for
      exotic rules but introduces a Rust FFI build step and a second filter
      engine.
    - The WebKit content-blocker is the enforcement point either way — the
      Rust engine would only replace the *parsing* layer.

## Apple Silicon notes

- Rust toolchain adds cross-compilation complexity for universal
      builds (arm64 + x86_64) and the PacketTunnel's build graph.

## Adoption sketch

- Keep the Swift compiler; use adblock-rust only as an offline
      conformance oracle for rule parsing (build-time CLI), not a runtime dep.

## Risks

- MPL-2.0 is fine file-wise; the FFI + build-system cost is the real
      price. Two filter parsers can disagree — dangerous for shield
      guarantees.

## Verdict: Hold — Swift compiler already ships; revisit for exotic rule coverage
