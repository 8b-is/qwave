# WebURL (`karwa/swift-url`)

| | |
|---|---|
| **Repo** | https://github.com/karwa/swift-url |
| **Version** | **0.4.2** (Jul 1) |
| **License** | Apache 2.0 |
| **Platforms** | macOS, iOS, Linux, Windows — pure Swift, no system dependency |
| **Apple Silicon** | Pure Swift; arm64-native, no C shims |
| **Verified** | 2026-08-12 |

---

## What it is

A Swift implementation of the **WHATWG URL Standard** — the specification browsers actually
implement, as opposed to the RFC 3986 lineage that Foundation's `URL` descends from. It ships
internationalised domain name support, host-parsing APIs, and Foundation interop for converting
to and from `URL`.

## Why it matters for Qwave

This is the highest-value, lowest-risk package in the entire research folder, and the reason is
a correctness gap that is also a security gap.

Foundation's `URL` and WebKit disagree about what a URL *means*. Concretely:

| Input | Foundation `URL` | WHATWG (what WebKit loads) |
|-------|------------------|----------------------------|
| `http:\\example.com\` | fails or misparses | normalises backslashes → `http://example.com/` |
| `https://еxample.com` (Cyrillic `е`) | host preserved as typed | punycode → `xn--xample-2of.com` |
| `http://example.com:80/` | port retained | default port elided |
| `https://user@evil.com@good.com/` | ambiguous | host is `good.com` |

Now look at where Qwave makes host-keyed decisions:

- **`Shields/ShieldsPolicy.swift`** — per-host JavaScript toggles.
- **`Shields/HTTPSFirstUpgrader.swift`** — scheme rewriting.
- **`BrowserCore/OmniboxParser.swift`** — deciding "is this a URL or a search query?"
- **`Persistence/HistoryStore.swift`** — host-keyed history records.

If `OmniboxParser` computes a different host than the one WebKit ends up navigating to, a page
can be **shielded under one identity and loaded under another**. That is a real bypass class,
not a theoretical one, and the IDN row above is how it is usually reached.

`OmniboxParser` also has a second job WebURL directly serves: the URL-versus-search-query
decision. That heuristic is fiddly, every browser tunes it, and getting it wrong either
searches for a URL the user typed or navigates to a search phrase. Spec-accurate parsing is the
correct foundation for that heuristic.

## Apple Silicon notes

Pure Swift with no C interop, so it compiles arm64-native with no bridging overhead. Its parsing
is allocation-conscious and operates over UTF-8 views — worth benchmarking against Foundation
on the omnibox hot path, where the parser runs on every keystroke. On M-series, where memory
bandwidth is the binding constraint for this kind of work, fewer intermediate `String`
allocations is the win, not raw instruction count.

## Adoption sketch

```swift
// Package.swift
.package(url: "https://github.com/karwa/swift-url", from: "0.4.2")
// then: .target(name: "BrowserCore", dependencies: [.product(name: "WebURL", package: "swift-url"), ...])
```

```swift
// Shields/ShieldsPolicy.swift — one canonical host, used everywhere
import WebURL

func canonicalHost(of string: String) -> String? {
    guard let url = WebURL(string) else { return nil }
    return url.host?.serialized      // already punycode-normalised
}
```

The migration is mechanical and testable: introduce `canonicalHost` in one place, route
`ShieldsPolicy`, `HTTPSFirstUpgrader`, `OmniboxParser`, and `HistoryStore` through it, and add
the confusable/IDN cases above to `ShieldsPolicyTests` and `OmniboxParserTests`.

## Risks

- **Pre-1.0 (0.4.x).** The API can still change between minor versions. Mitigate by keeping
  `WebURL` behind a thin `canonicalHost`-style boundary in `QwaveSupport` rather than sprinkling
  the type through five modules — that also makes the whole thing revertible.
- **Bus factor.** A single-maintainer package. The spec it implements is stable and the code is
  well tested, but this belongs in the risk column for a security-relevant dependency.
- **Two URL types in one codebase.** `WebURL` and `Foundation.URL` will coexist, because WebKit
  APIs take `URL`. Convert at the boundary, deliberately, in one place.

## Verdict

🟢 **Adopt.**

Spec-accurate URL parsing is not optional in a browser that makes per-host security decisions,
and the current gap is a genuine bypass surface. The pre-1.0 version is a real caveat — contain
it behind a `QwaveSupport` shim and the exposure is a handful of call sites.

**First step:** write the failing test before adding the dependency. Feed the confusable-IDN and
backslash cases from the table above into the existing `ShieldsPolicyTests` and watch what the
current implementation does.
