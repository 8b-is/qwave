# WebKit for SwiftUI (`WebView` / `WebPage`)

| | |
|---|---|
| **Source** | Apple platform framework (`import WebKit`) |
| **Introduced** | WWDC25 — session 231, "Meet WebKit for SwiftUI" |
| **Availability** | macOS 26+ / iOS 26+ |
| **License** | Apple SDK |
| **Apple Silicon** | Native; WebKit's multi-process model is arm64-native throughout |
| **Verified** | 2026-08-12 |

---

## What it is

A first-party SwiftUI surface for WebKit, replacing the `NSViewRepresentable`-wrapping-`WKWebView`
dance that every SwiftUI app has written by hand since 2019.

Two types carry it:

- **`WebView`** — a SwiftUI view. Hand it a URL and it loads and displays the content.
- **`WebPage`** — an `@Observable` class representing the web content itself. It loads, controls,
  and communicates with the page, and it is designed for Swift concurrency from the ground up
  rather than retrofitted onto a delegate protocol.

`WebPage` is not limited to URLs — it loads HTML strings against a base URL directly. View
modifiers such as `webViewScrollPosition` and `findNavigator` cover behaviour that previously
required reaching into the `WKWebView` internals.

## Why it matters for Qwave

Qwave is an **AppKit shell with SwiftUI control panes** (`Sources/QwaveApp/SettingsWindow/*`).
The web content itself lives in `WebViewContainerView.swift` and is created by
`BrowserCore/WebViewFactory.swift`. That split is deliberate and correct — but three existing
files are hand-rolled versions of things `WebPage` now provides:

| Qwave file | What `WebPage` offers |
|------------|----------------------|
| `BrowserCore/NavigationCoordinator.swift` | Observable navigation state instead of `WKNavigationDelegate` callbacks |
| `BrowserCore/FindInPageController.swift` | `findNavigator` modifier |
| `QwaveApp/FindBarView.swift` | The system find UI, matching Safari's behaviour and keybindings |

The strategic value is larger than the line count. `WebPage` being `@Observable` means tab state
becomes ordinary SwiftUI state, which is exactly what `TabManager` currently reimplements.

## Apple Silicon notes

Nothing Apple Silicon-specific in the API surface. The relevant fact is generational: **Metal 4
and the macOS 26 WebKit stack are Apple Silicon-only**, so anything built on this baseline
inherits an arm64-only floor for free — which matches Qwave's stance anyway.

## Adoption sketch

Gate it. Qwave's floor is macOS 14; this API's floor is macOS 26.

```swift
// BrowserCore/WebViewFactory.swift — additive, not a replacement
@available(macOS 26.0, *)
func makeWebPage(for tab: Tab, in container: ContainerIdentifier) -> WebPage {
    var config = WebPage.Configuration()
    config.websiteDataStore = ContainerRegistry.shared.dataStore(for: container)
    return WebPage(configuration: config)
}
```

The container isolation model carries over unchanged — `WebPage.Configuration` still takes a
`WKWebsiteDataStore`, so Firefox-style Container Universes work exactly as they do today.

**Suggested spike:** render the Settings *preview* pane with `WebView` before touching the
browsing surface. It exercises the API against real content with zero blast radius.

## Risks

- **macOS 26 floor.** Three majors above Qwave's target. This is a parallel code path, not a
  migration, until the deployment target moves.
- **SPI reachability is unproven.** Qwave's `FeatureFlags` module reflects over `_WKFeature` on
  the underlying `WKWebViewConfiguration`. Whether `WebPage.Configuration` exposes an equivalent
  hook needs to be tested before any real migration — if it does not, the Safari SPI feature-flag
  pane cannot follow.
- **Maturity.** A first-generation SwiftUI wrapper over a very large framework. Expect gaps at
  the edges — download handling, custom scheme handlers, per-navigation policy decisions.

## Verdict

🟢 **Adopt — gated and additive.**

Build it behind `@available(macOS 26.0, *)` as a second rendering path. Do not delete
`WebViewContainerView` or `NavigationCoordinator`. Revisit promoting it to primary when Qwave's
deployment target reaches macOS 26.

The `FeatureFlags` SPI question is the gating unknown and should be answered first — it is
cheap to test and it determines whether this path is ever viable as a *replacement* rather than
an alternative.

---

**Reference:** [Meet WebKit for SwiftUI — WWDC25 session 231](https://developer.apple.com/videos/play/wwdc2025/231/)
