# 06 · Networking & Protocols

| Package | Version | Verdict | Qwave module |
|---------|---------|---------|--------------|
| [swift-http-types](swift-http-types.md) | 1.6.0 | 🟡 Assess | `VPNKit/MullvadAPIClient` |
| [SwiftNIO](swift-nio.md) | 2.101.3 | 🔴 Hold | — |
| [AsyncHTTPClient](async-http-client.md) | 1.36.0 | 🔴 Hold | — |

---

## Why this category is mostly Hold

**Qwave does almost no networking, and that is by design.**

| Traffic | Who handles it |
|---------|----------------|
| Web content | WebKit's networking process — Qwave never sees a byte |
| VPN tunnel | `PacketTunnel.systemextension` via `NETunnelProviderManager` and WireGuard |
| Mullvad API | `VPNKit/MullvadAPIClient.swift` — a handful of JSON REST calls |
| Blocklist fetch | `Shields/BlocklistUpdater.swift` — periodic file download |

Only the last two are Qwave's own code, and both are served completely by `URLSession`.

This is not a limitation to route around. It is the correct architecture: a browser that
implements its own HTTP stack alongside WebKit's has two TLS configurations, two proxy
behaviours, two cookie jars, and two sets of security bugs.

## The one thing worth watching

`URLSession` is not merely adequate here — it is **better**, because it integrates with the
system network stack that the VPN reconfigures. When the WireGuard tunnel comes up,
`URLSession` traffic follows the system routing table. A NIO-based client with its own event
loop and socket configuration is a place where traffic can leak outside the tunnel.

For a browser whose selling point is a VPN, **leak-proofing is the requirement**, and it argues
directly against every third-party networking stack in this category.

## What is worth taking

Only [swift-http-types](swift-http-types.md), and only as shared vocabulary types — not as a
transport. Apple's own `URLSession` integration means adopting them does not mean adopting a
networking stack, which is exactly the distinction that makes it worth a look at all.
