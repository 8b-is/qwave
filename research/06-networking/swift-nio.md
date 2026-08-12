# SwiftNIO (`apple/swift-nio`)

| | |
|---|---|
| **Repo** | https://github.com/apple/swift-nio |
| **Version** | **2.101.3** (Jul 15) |
| **License** | Apache 2.0 |
| **Platforms** | macOS, iOS, Linux, Windows, Android |
| **Apple Silicon** | Native; uses `kqueue` on Darwin |
| **Verified** | 2026-08-12 |

---

## What it is

Apple's event-driven, non-blocking network application framework — the foundation of the Swift
server ecosystem, and an SSWG Graduated project. It provides an event-loop architecture, a
channel pipeline model, and high-performance protocol implementations for HTTP/1, HTTP/2,
WebSocket, and TLS (via `swift-nio-ssl` and BoringSSL).

It is excellent, and it is built for servers.

## Why it matters for Qwave

**It does not, and the reason is worth writing down carefully — because a browser looks like it
should want a networking framework.**

### Qwave does not own the network stack

WebKit handles all web content networking in its own process, with its own TLS, cookie, cache,
and proxy configuration. Qwave never sees page traffic. What is left is `MullvadAPIClient`'s
REST calls and `BlocklistUpdater`'s file download — both trivially served by `URLSession`.

### It would actively harm the VPN

This is the strongest argument, not merely an absence of benefit.

`URLSession` uses the system network stack. When the WireGuard tunnel is up, the system routing
table sends `URLSession` traffic through it — automatically, including proxy settings, ATS
policy, and DNS.

NIO opens its own sockets on its own event loops with its own configuration. Making that
reliably tunnel-aware is work, and getting it wrong means **traffic leaking outside the VPN**.
For a browser whose feature list leads with Mullvad integration, that is not a trade-off; it is
a defect.

### The tunnel is not a NIO use case either

`PacketTunnel.systemextension` operates at the packet level via `NEPacketTunnelProvider`,
handing IP packets to WireGuard's Go implementation (`libwg-go.a`). That is below NIO's
abstraction level entirely.

## Apple Silicon notes

NIO is well-optimised on Darwin, using `kqueue` for its event loops and scaling across
performance cores. Irrelevant here — and worth noting that spinning up event loop threads in a
browser process works against `EnergyGovernor`, which exists to keep cores idle.

## Adoption sketch

None.

For the two networking needs Qwave actually has, `URLSession` with async/await is the answer:

```swift
let (data, response) = try await URLSession.shared.data(from: relayListURL)
```

System proxy support, tunnel-aware routing, ATS, and URL cache behaviour all come for free —
and all of them would need reimplementing on NIO.

## Risks

Not applicable. The risk being documented is **adoption**: a NIO-based client in a VPN browser
is a leak surface, and that is a security regression rather than an architectural preference.

## Verdict

🔴 **Hold.**

A superb framework for servers, and the wrong tool for a browser shell that deliberately does not
own its network stack.

**The rule worth recording:** Qwave uses `URLSession` for all app-level networking, specifically
because it follows system routing when the VPN is active. Any proposal to introduce a
non-`URLSession` HTTP client must first answer how it stays inside the tunnel.
