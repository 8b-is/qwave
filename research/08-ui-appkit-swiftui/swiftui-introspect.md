# SwiftUI Introspect (`siteline/swiftui-introspect`)

| | |
|---|---|
| **Repo** | https://github.com/siteline/swiftui-introspect |
| **Version** | **27.0.0 Beta 2** (Jul 8) — watchOS support removed; macOS floor raised to 12 |
| **License** | MIT |
| **Platforms** | macOS, iOS, tvOS, visionOS |
| **Apple Silicon** | Pure Swift |
| **Verified** | 2026-08-12 |

---

## What it is

A library for reaching the **underlying AppKit or UIKit view** behind a SwiftUI view. When
SwiftUI does not expose a property you need — scroller style, text field focus ring, table row
height — Introspect walks the view hierarchy at runtime and hands you the `NSView` so you can
set it directly.

It is a well-maintained escape hatch, and it tracks OS releases closely — the 27.0.0 line already
targets Xcode 27 and OS 26 runtimes, which is a good signal about maintenance quality.

## Why it matters for Qwave

Marginally, because Qwave's architecture already has a better escape hatch.

Introspect exists to solve "I need AppKit control inside a SwiftUI view". Qwave is an **AppKit
app** with SwiftUI panes. When AppKit control is needed, the answer is to write AppKit — which is
what `BrowserWindowController`, `TabBarView`, and `OmniboxField` already do.

The plausible cases are confined to `SettingsWindow/*`:

| Want | Introspect | Better option |
|------|-----------|---------------|
| Custom scroller styling in a pane | `introspect(.scrollView)` | `NSHostingView` inside an `NSScrollView` you control |
| First responder on a text field | `introspect(.textField)` | `@FocusState` — native since macOS 12 |
| Table row height in the Library | `introspect(.tableView)` | `NSTableView` directly; the Library list is a good AppKit candidate anyway |
| Window-level behaviour | `introspect(.window)` | `NSWindow` from the controller that created it |

In every row, the alternative is available because Qwave already owns the AppKit layer. An app
built SwiftUI-first has no such option — which is exactly the app Introspect is for.

## Apple Silicon notes

None. Pure Swift with no architecture-specific behaviour.

## Adoption sketch

If a genuine need appears:

```swift
.package(url: "https://github.com/siteline/swiftui-introspect", from: "27.0.0")
```

```swift
List { /* ... */ }
    .introspect(.list, on: .macOS(.v14, .v15, .v26)) { tableView in
        tableView.usesAlternatingRowBackgroundColors = true
    }
```

Note the version-matrix argument. That is Introspect's fundamental cost: **the view hierarchy it
walks is private implementation detail**, so every OS release is a potential break, and you must
enumerate the versions you support.

## Risks

- **Depends on private view hierarchy structure.** SwiftUI can restructure its backing views in
  any release. Introspect keeps up, but "keeps up" means your app breaks until you take the
  update — an unattractive property in a browser.
- **Currently on a beta line** (27.0.0 Beta 2) tracking Xcode 27 and OS 26 runtimes.
- **macOS 12 floor** in the current line — fine for Qwave's macOS 14 target.
- **Qwave has a better hatch.** Every use case has a first-party alternative because the AppKit
  layer already exists.

## Verdict

🟡 **Assess — a good library that Qwave's architecture makes largely unnecessary.**

Introspect is the right answer for a SwiftUI-first app that occasionally needs AppKit. Qwave is
an AppKit app that occasionally uses SwiftUI, which is the inverse — and the inverse has a
first-party solution: write the AppKit view.

**The rule worth recording:** when a Settings pane needs AppKit-level control, prefer hosting an
`NSView` over introspecting a SwiftUI one. Depending on SwiftUI's private view hierarchy is a
recurring maintenance cost in exchange for avoiding code Qwave is already comfortable writing.
