# KeyboardShortcuts (`sindresorhus/KeyboardShortcuts`)

| | |
|---|---|
| **Repo** | https://github.com/sindresorhus/KeyboardShortcuts |
| **Version** | **3.0.1** (Jun 17) — "Fix release build crash with Swift 6.3 compiler" |
| **License** | MIT |
| **Platforms** | macOS only |
| **Apple Silicon** | Native; wraps Carbon hotkey APIs where required |
| **Verified** | 2026-08-12 |

---

## What it is

The standard macOS package for **user-customisable keyboard shortcuts**. It provides a recorder
control the user can click and press a key combination into, persistence of the choice, conflict
detection, and both global (system-wide) and local (app-scoped) shortcut registration.

It handles the parts that are genuinely unpleasant: the Carbon hotkey API for global shortcuts,
modifier normalisation, and rendering key combinations the way macOS renders them.

## Why it matters for Qwave

`QwaveApp/MainMenu.swift` defines a fixed set of shortcuts. Every serious browser lets users
rebind them, and for a power-user-oriented sovereign browser it is squarely on-brand.

Browser-specific shortcuts worth making rebindable:

| Action | Qwave module |
|--------|--------------|
| New burner tab | `BrowserCore/ContainerRegistry` — ephemeral non-persistent store |
| Switch container | `ContainerRegistry` |
| Toggle shields for this site | `Shields/ShieldsPolicy` + `ShieldsPopover` |
| Toggle VPN | `VPNKit/TunnelManager` + `VPNStatusItem` |
| Hibernate this tab | `BrowserCore/TabHibernator` |
| Find in page | `BrowserCore/FindInPageController` |

The container and shield toggles are the interesting ones. They are Qwave-specific actions with
no Safari equivalent, so users have no muscle memory to preserve — which makes rebinding more
valuable, not less.

```swift
// Declare once
extension KeyboardShortcuts.Name {
    static let newBurnerTab   = Self("newBurnerTab",   default: .init(.n, modifiers: [.command, .shift]))
    static let toggleShields  = Self("toggleShields",  default: .init(.s, modifiers: [.command, .shift]))
    static let hibernateTab   = Self("hibernateTab",   default: .init(.h, modifiers: [.command, .control]))
}

// Handle
KeyboardShortcuts.onKeyUp(for: .newBurnerTab) { [weak self] in
    self?.tabManager.openBurnerTab()
}
```

The recorder drops straight into a new Settings pane alongside `ShieldsPane`, `VPNPane`, and
`ContainersPane`:

```swift
KeyboardShortcuts.Recorder("New burner tab:", name: .newBurnerTab)
```

## Apple Silicon notes

No architecture-specific behaviour. One platform note that matters more than the architecture:
**global** shortcuts require Accessibility or Input Monitoring permission on modern macOS, which
is a permission prompt a privacy-focused browser should think twice about requesting.

**Local (app-scoped) shortcuts need no special permission**, and local is all a browser needs.
Use `onKeyUp`/`onKeyDown` in the app scope and never request global registration — the
sovereignty story is worth more than a global hotkey.

## Adoption sketch

```swift
.package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "3.0.1")
```

Add a `ShortcutsPane` to `SettingsWindow/`, following the existing pane pattern, and route the
handlers through `BrowserEnvironment.swift` so they reach the same code paths the menu items do.

Shortcut assignments should live wherever the rest of Qwave's settings live — see
[Defaults](defaults.md) for that question — so an exported settings bundle carries them.

## Risks

- **Global shortcuts need invasive permissions.** Stay app-scoped. Document the decision so it is
  not "fixed" later.
- **Conflicts with system and web shortcuts.** Web pages capture keystrokes too. Rebinding to
  something a page intercepts produces confusing behaviour. Reserve a safe modifier space and
  warn on system-reserved combinations.
- **Carbon under the hood.** Global registration uses long-deprecated-but-stable Carbon APIs. Low
  risk historically, non-zero over a long horizon. Local-only usage reduces exposure.
- **The 3.0.1 fix is a signal.** A release build crash under the Swift 6.3 compiler was fixed in
  this version — worth pinning at or above 3.0.1 and testing release builds specifically.

## Verdict

🔵 **Trial — app-scoped shortcuts only.**

The de facto standard for this on macOS, small, MIT-licensed, and it delivers a genuine
power-user feature that fits Qwave's audience. The Qwave-specific actions — burner tabs,
container switching, shield toggles — are the ones users most benefit from binding themselves.

**Constraint:** never request Accessibility or Input Monitoring permission. Local shortcuts cover
every browser use case, and a privacy-first browser asking to monitor input is a contradiction
users will notice.
