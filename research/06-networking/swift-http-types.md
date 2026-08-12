# swift-http-types (`apple/swift-http-types`)

| | |
|---|---|
| **Repo** | https://github.com/apple/swift-http-types |
| **Version** | **1.6.0** (Jun 5) |
| **License** | Apache 2.0 |
| **Platforms** | All Swift platforms |
| **Apple Silicon** | Pure Swift |
| **Verified** | 2026-08-12 |

---

## What it is

Apple's shared vocabulary types for HTTP: `HTTPRequest`, `HTTPResponse`, `HTTPFields`,
`HTTPField.Name`. Version-agnostic across HTTP/1.1, HTTP/2, and HTTP/3, and deliberately
**transport-independent** — they describe HTTP messages without implementing a client or server.

1.6.0 raised the tools version to 6.0, added known header field names from RFC 9842 and the W3C
Trace Context spec, renamed `dictionaryId` to `dictionaryID`, and introduced a `FoundationURL`
trait.

That last item matters: the trait lets the package avoid a hard Foundation dependency, which is
the kind of care that makes a vocabulary package safe to adopt broadly.

## Why it matters for Qwave

Modest but real, in exactly one place: **`VPNKit/MullvadAPIClient.swift`**.

That file makes JSON REST calls to Mullvad's API — account validation, device registration, relay
list fetching. Today that means `URLRequest` and `HTTPURLResponse`, whose ergonomics are
showing their age:

```swift
// Foundation — stringly-typed headers, optional-heavy response handling
var request = URLRequest(url: url)
request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw ... }

// HTTPTypes — typed field names, non-optional status
var request = HTTPRequest(method: .get, url: url)
request.headerFields[.authorization] = "Bearer \(token)"
guard response.status == .ok else { throw ... }
```

`HTTPField.Name` catches header typos at compile time, and `HTTPResponse.Status` is a real type
rather than an `Int` you compare against magic numbers.

Apple ships `URLSession` integration for these types, which is the crucial property: **adopting
the vocabulary does not mean adopting a transport**. Qwave keeps `URLSession` — and with it,
system proxy support, tunnel-aware routing, and ATS — while getting better types on top.

`MockURLProtocol.swift` in `VPNKitTests` already exists to intercept `URLSession` traffic, so the
existing test approach survives unchanged.

## Apple Silicon notes

None — pure Swift value types with no architecture-specific behaviour and no runtime cost of
consequence.

## Adoption sketch

```swift
.package(url: "https://github.com/apple/swift-http-types", from: "1.6.0"),
// on the VPNKit target:
.product(name: "HTTPTypesFoundation", package: "swift-http-types")
```

```swift
import HTTPTypes
import HTTPTypesFoundation

// URLSession is still the transport — only the vocabulary changed
let (data, response) = try await URLSession.shared.data(for: httpRequest)
```

Confine it to `VPNKit`. `Shields/BlocklistUpdater` does a plain file download where the
vocabulary adds nothing.

## Risks

- **Small benefit for one file.** `MullvadAPIClient` is the only meaningful consumer. Weigh a
  dependency against typed headers in one place — and note that a small hand-rolled
  `enum HeaderName` would capture most of the benefit with none of the dependency.
- **Two HTTP vocabularies in one codebase.** `HTTPTypes` in `VPNKit`, Foundation types
  elsewhere. Contained, but worth being deliberate about.
- **Transitive Foundation interop.** The `HTTPTypesFoundation` product is what makes this
  practical; check it stays aligned with the `FoundationURL` trait work in 1.6.0.

## Verdict

🟡 **Assess — good types, narrow application.**

Apple-maintained, well-designed, and the `URLSession` integration means it can be adopted without
touching the transport — which preserves the leak-proofing argument in the
[category README](README.md).

The case is simply not strong: one file benefits. Worth adopting **if `VPNKit`'s API surface
grows** — Stage B of the VPN work would qualify. Not worth a dependency for the current handful
of endpoints.
