# swift-certificates (`apple/swift-certificates`)

| | |
|---|---|
| **Repo** | https://github.com/apple/swift-certificates |
| **Version** | **1.19.4** (Jul 28) |
| **License** | Apache 2.0 |
| **Platforms** | All Swift platforms |
| **Depends on** | `apple/swift-asn1`, [swift-crypto](swift-crypto.md) |
| **Apple Silicon** | Pure Swift |
| **Verified** | 2026-08-12 |

---

## What it is

Apple's package for X.509 certificate handling in Swift: parsing, serialisation, chain
verification with a pluggable policy system, and certificate creation. It builds on
`swift-asn1` for DER encoding and `swift-crypto` for signature verification.

The 1.19.4 release rejected chains where `directoryName` name constraints are involved — a
correctness fix in verification policy, which is the kind of detail that indicates active
security maintenance rather than feature-chasing.

## Why it matters for Qwave

Two distinct opportunities, with very different risk profiles.

### 1. Pinning the Mullvad API (the good one)

`VPNKit/MullvadAPIClient.swift` talks to Mullvad's API to validate accounts, register devices,
and fetch the relay list. Today that trusts the system trust store — meaning any of the hundreds
of trusted CAs can issue a certificate for that host.

For a **sovereignty-focused browser talking to a privacy service**, that is exactly the threat
model worth hardening. A mis-issued or coerced certificate on the relay-list endpoint is a
position from which to feed a user a manipulated relay set.

```swift
// VPNKit — verify the pinned public key on the API connection
import X509

func validate(_ chain: [Certificate]) throws {
    guard let leaf = chain.first,
          leaf.publicKey == MullvadPinnedKeys.current || leaf.publicKey == MullvadPinnedKeys.backup
    else { throw VPNError.certificatePinMismatch }
}
```

Note the backup pin. Pinning without a rotation path is how apps brick themselves.

### 2. Certificate inspection UI (the tempting one)

Browsers show certificate details when the user clicks the padlock. Qwave has no such UI today.

But **WebKit already validates web content certificates**, and its result is what actually
governs whether a page loads. A second validation path in the app that disagrees with WebKit's
is worse than no UI at all — it either shows the user something untrue or creates a
distinction with no security meaning.

If certificate UI is ever built, source it from WebKit's own `serverTrust` on the navigation
delegate, and use swift-certificates only for **display formatting** — never for a competing
trust decision.

## Apple Silicon notes

Pure Swift with no architecture-specific code. Verification cost is dominated by signature
checks, which route through swift-crypto to Apple Silicon's accelerated paths. For pinning a
single API host, the cost is irrelevant.

## Adoption sketch

```swift
.package(url: "https://github.com/apple/swift-certificates", from: "1.19.4"),
// on VPNKit:
.product(name: "X509", package: "swift-certificates")
```

Pinning integrates through `URLSessionDelegate`, which keeps `URLSession` as the transport —
preserving the tunnel-aware routing argument from [category 06](../06-networking/README.md):

```swift
func urlSession(_ session: URLSession,
                didReceive challenge: URLAuthenticationChallenge) async
    -> (URLSession.AuthChallengeDisposition, URLCredential?) {
    // Validate the pin, then accept or reject.
}
```

`VPNKitTests/MockURLProtocol.swift` already intercepts `URLSession`, so pin-mismatch cases are
testable without network access.

## Risks

- **Pinning bricks apps when certificates rotate.** The single largest operational risk. Mitigate
  with multiple pins (current + backup), pin the CA or intermediate rather than the leaf if
  Mullvad's rotation cadence warrants it, and ship a documented recovery path.
- **Pin maintenance is ongoing.** A pin is a commitment to track someone else's certificate
  lifecycle indefinitely.
- **Do not compete with WebKit on web content.** Restated because it is the mistake this package
  makes easy.
- **Dependency depth.** Pulls in `swift-asn1` and `swift-crypto`. All Apple-maintained, but it is
  three additions rather than one.

## Verdict

🔵 **Trial — scoped to pinning the Mullvad API.**

Certificate pinning on the VPN control plane is a real hardening measure that fits Qwave's threat
model precisely: the product's premise is not trusting intermediaries, and the system trust store
is a large set of intermediaries.

Held at Trial rather than Adopt because **pin rotation must be designed before it is
implemented**. Ship with backup pins and a documented recovery path, or do not ship it.

**Explicitly out of scope:** any validation of web content certificates. That is WebKit's job,
and a second opinion there is a liability.
