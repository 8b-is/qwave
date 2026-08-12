# WebURL

| Fact | Value |
|---|---|
| **Repo** | https://github.com/karwa/swift-weburl |
| **Latest version** | 0.4.2 (verified 2026-08-12) |
| **License** | Apache-2.0 |
| **Platforms** | All Swift platforms |
| **Apple Silicon status** | ✅ Native (pure Swift, WHATWG URL) |

## What it is

A Swift implementation of the WHATWG URL standard with a
    Foundation-`URL`-compatible API surface.

## Why it matters for Qwave

- **Security-critical**: Foundation `URL.host` and WebKit disagree on
      IDN/confusable hosts, backslashes, and `user@evil@good` authority
      parsing. `ShieldsPolicy.resolvedPolicy(forHost:)` can shield a page
      under one identity while WebKit loads another — a bypass class.
    - One canonical parser for omnibox, shields policy, and container keys
      closes that hole.

## Apple Silicon notes

- Pure Swift, no platform quirks; the reference implementation passes
      the WHATWG test suite.

## Adoption sketch

- Adopt in `BrowserCore.OmniboxParser` and `Shields.ShieldsPolicy` as
      the canonical host/URL identity source.

## Risks

- API is 0.x; pin exactly. Not a drop-in for every `URL` use — use it
      where *identity* matters (policy decisions), keep Foundation URL for
      file/loading APIs.

## Verdict: Adopt — closes a real shielding bypass
