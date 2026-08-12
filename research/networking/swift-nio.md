# SwiftNIO

| Fact | Value |
|---|---|
| **Repo** | https://github.com/apple/swift-nio |
| **Latest version** | 2.8x (2026-08, re-verify) |
| **License** | Apache-2.0 (Swift license) |
| **Platforms** | All Swift platforms |
| **Apple Silicon status** | ✅ Native (pure Swift + Network.framework) |

## What it is

Apple's non-blocking event-driven networking framework.

## Why it matters for Qwave

- **Traffic-leak surface**: in a VPN browser, `URLSession` follows the
      system routing table (through the tunnel) while raw NIO sockets do not
      by default. Introducing NIO for any app-level HTTP would silently route
      traffic around the tunnel.
    - `VPNKit.MullvadAPIClient` and the blocklist updater MUST stay on
      URLSession; NIO would only ever be justified inside the tunnel
      extension itself (where it isn't needed).

## Apple Silicon notes

- NIO's Network.framework integration (`NIOTS`) inherits system
      routing; plain sockets do not.

## Adoption sketch

- No adoption planned; document the routing constraint in VPNKit.

## Risks

- Subtle but severe: split-horizon routing bugs ship quietly.

## Verdict: Hold — routing semantics incompatible with VPN guarantees
