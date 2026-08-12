# AsyncHTTPClient (`swift-server/async-http-client`)

| | |
|---|---|
| **Repo** | https://github.com/swift-server/async-http-client |
| **Version** | **1.36.0** (Jul 23) |
| **License** | Apache 2.0 |
| **Platforms** | macOS, Linux |
| **Built on** | [SwiftNIO](swift-nio.md) |
| **Apple Silicon** | Native via NIO |
| **Verified** | 2026-08-12 |

---

## What it is

The Swift Server Work Group's HTTP client, built on SwiftNIO. It provides async/await request
execution, HTTP/1 and HTTP/2 support, connection pooling, streaming request and response bodies,
and — as of 1.36.0 — proxy-header support.

On Linux, where `URLSession`'s implementation is less complete, it is close to essential. On
Darwin, it is an alternative to a first-party API that is already very good.

## Why it matters for Qwave

**It does not**, and the reasoning is the same as [SwiftNIO](swift-nio.md)'s, with one addition.

Qwave's total app-level networking is `MullvadAPIClient`'s REST calls and `BlocklistUpdater`'s
periodic download. `URLSession` covers both completely, with async/await, and with
`MockURLProtocol`-based testing already in place in `VPNKitTests`.

### The VPN argument, restated

`URLSession` follows the system routing table, so when the WireGuard tunnel is active, app
traffic goes through it. AsyncHTTPClient inherits NIO's own socket and event-loop management —
making it reliably tunnel-aware is work, and failing at it means **leaking traffic outside the
VPN**.

The 1.36.0 proxy-header support is genuinely useful in server contexts. It is also a reminder
that proxy handling is something you must implement and maintain here, whereas `URLSession`
picks up the system proxy configuration — including whatever the tunnel sets — without code.

### Streaming does not change the answer

The one place a streaming client could plausibly help is downloading large blocklists in
`BlocklistUpdater`. But `URLSession.bytes(for:)` streams natively, and
`URLSessionDownloadTask` handles large file downloads with background support and resume
semantics that AsyncHTTPClient does not offer on Darwin.

## Apple Silicon notes

No Apple Silicon-specific concerns. Worth restating from the NIO note: NIO event loop threads in
a browser process work against `EnergyGovernor`, whose purpose is keeping cores idle. `URLSession`
uses shared system infrastructure already running for other reasons.

## Adoption sketch

None. The existing approach is correct:

```swift
// VPNKit/MullvadAPIClient.swift — already the right answer
let (data, response) = try await URLSession.shared.data(for: request)
```

## Risks

Not applicable — the recommendation is not to adopt. Documented so that "we should use a real
HTTP client" resolves quickly, with the leak argument attached.

## Verdict

🔴 **Hold.**

The correct choice for server-side Swift and for Linux, and the wrong choice inside a macOS
browser that ships a VPN. `URLSession` is not a fallback here; it is the better option, because
it inherits system routing, proxy configuration, and ATS — the properties that keep traffic
inside the tunnel.
