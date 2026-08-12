# 08 · UI: AppKit & SwiftUI

| Package | Version | Verdict | Qwave module |
|---------|---------|---------|--------------|
| [KeyboardShortcuts](keyboard-shortcuts.md) | 3.0.1 | 🔵 Trial | `QwaveApp/MainMenu`, Settings |
| [Defaults](defaults.md) | 9.0.9 | 🔵 Trial | `Persistence/SettingsStore` |
| [swift-navigation](swift-navigation.md) | 2.11.0 | 🟡 Assess | Settings + Library windows |
| [SwiftUI Introspect](swiftui-introspect.md) | 27.0.0-beta.2 | 🟡 Assess | Settings panes |

---

## The architecture constraint

Qwave is a **thin AppKit shell with SwiftUI control panes**. That is not an accident of history —
it is the correct design for a browser:

| Surface | Framework | Why |
|---------|-----------|-----|
| `BrowserWindowController`, `TabBarView`, `OmniboxField` | **AppKit** | Precise control over first responder, focus, drag-and-drop, and window behaviour. Browsers live or die on these. |
| `WebViewContainerView` | **AppKit** | Hosts `WKWebView` directly with no wrapper indirection |
| `SettingsWindow/*`, `LibraryWindow` | **SwiftUI** | Form-shaped UI where SwiftUI is genuinely faster to build |

This split determines every verdict in this category: **packages that assume a SwiftUI-first app
have less to offer here than their popularity suggests.**

## What is actually missing

Looking at `Sources/QwaveApp/`, the real gaps are not framework-level:

1. **User-customisable keyboard shortcuts.** `MainMenu.swift` defines fixed shortcuts. Every
   serious browser lets users rebind them, and it is a genuine power-user feature.
2. **Type-safe preferences.** `Persistence/SettingsStore.swift` is SQLite-backed, which is
   unusual — most Mac apps use `UserDefaults`. Both work; the question is whether the SQLite
   route is paying for itself.
3. **Live-updating Library window.** Covered by GRDB's `ValueObservation` — see
   [category 05](../05-persistence-data/grdb.md), not here.

Items 1 and 2 are what the two Trial entries address.

## The AppKit reality

The Point-Free ecosystem, SwiftUI Introspect, and most of the modern Swift UI package landscape
target SwiftUI. Qwave's most complex UI — tab bar, omnibox, find bar, window management — is
AppKit and should stay AppKit.

That is why this category is thinner than a typical Mac app's would be, and why the two most
useful entries ([KeyboardShortcuts](keyboard-shortcuts.md) and [Defaults](defaults.md)) are the
two that work equally well in both worlds.
