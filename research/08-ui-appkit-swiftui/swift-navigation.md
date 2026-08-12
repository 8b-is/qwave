# swift-navigation (`pointfreeco/swift-navigation`)

| | |
|---|---|
| **Repo** | https://github.com/pointfreeco/swift-navigation |
| **Version** | **2.11.0** (Jul 30) |
| **License** | MIT |
| **Platforms** | macOS, iOS, tvOS, watchOS |
| **Modules** | `SwiftNavigation`, `UIKitNavigation`, `AppKitNavigation` |
| **Apple Silicon** | Pure Swift |
| **Verified** | 2026-08-12 |

---

## What it is

Point-Free's library for **state-driven navigation**: modelling navigation as data rather than as
imperative calls. Instead of `present(controller, animated:)` scattered across a codebase, you
model destinations as an enum and bind the UI to it, so navigation state is inspectable,
testable, and restorable.

The package ships `SwiftNavigation` (framework-agnostic) plus UIKit and AppKit layers, so the
core idea is not SwiftUI-only. Release notes emphasise SwiftUI and UIKit; the AppKit module's
maturity relative to those is worth verifying directly before relying on it.

## Why it matters for Qwave

The idea is more valuable here than the package.

Qwave's window management is spread across `BrowserWindowController.swift`,
`SettingsWindowController.swift`, `LibraryWindow.swift`, and `AppDelegate.swift`. Windows are
created and shown imperatively. That works — and it means there is no single value describing
"what is currently open", which matters for two features Qwave already cares about:

- **`SessionRestorer`** restores tabs across launches. Restoring *window state* — which windows
  were open, which panes selected, which container active — is the natural extension, and it is
  much easier when that state is already a value.
- **Testing.** `SessionRestorerTests` can assert over data. It cannot assert over
  `showWindow(nil)`.

```swift
// The idea, independent of the package
enum WindowDestination: Equatable, Codable {
    case browser(containerID: ContainerID)
    case settings(pane: SettingsPane)
    case library(tab: LibraryTab)
}

@Observable final class AppNavigation {
    var open: [WindowDestination] = []      // restorable, testable, one source of truth
}
```

Adopting that pattern costs nothing and needs no dependency. The package adds bindings that
drive AppKit presentation from such state automatically — which is the part whose value depends
on how mature `AppKitNavigation` is.

## Apple Silicon notes

None. Pure Swift with no architecture-specific behaviour.

## Adoption sketch

If adopted, scope it to the SwiftUI windows first:

```swift
.package(url: "https://github.com/pointfreeco/swift-navigation", from: "2.11.0")
```

`SettingsWindow/SettingsRootView.swift` selects among `ShieldsPane`, `FeatureFlagsPane`,
`VPNPane`, and `ContainersPane` — a small, contained, genuinely state-driven navigation problem,
and a good place to evaluate the library without touching the browser window.

The browser window itself — tab bar, omnibox, find bar, web view — should stay AppKit and stay
imperative. Its navigation is not the kind this library models.

## Risks

- **AppKit support needs verification.** The release notes foreground SwiftUI and UIKit. Confirm
  the AppKit module's current coverage before depending on it for window management.
- **Small SwiftUI surface.** Two windows. The leverage is limited by architecture, not by the
  package's quality.
- **Ecosystem pull.** Point-Free libraries compose with each other and tend to arrive together.
  Adopting one is a decision about direction, not just about one dependency.
- **The core idea is free.** State-driven navigation as a *pattern* needs no package. Adopting the
  pattern captures most of the value at zero dependency cost.

## Verdict

🟡 **Assess — adopt the pattern, defer on the package.**

Modelling navigation as state is the right idea for Qwave, and it directly serves window session
restoration, which is a natural follow-on to the tab restoration already shipping.

But Qwave's SwiftUI surface is two windows, and its complex UI is AppKit by design. That caps the
package's leverage well below what it would be in a SwiftUI-first app. Introduce a
`WindowDestination` enum and an `@Observable` navigation model by hand; revisit the package if
window state management grows genuinely complex.
