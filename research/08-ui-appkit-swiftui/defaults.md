# Defaults (`sindresorhus/Defaults`)

| | |
|---|---|
| **Repo** | https://github.com/sindresorhus/Defaults |
| **Version** | **9.0.9** (Jun 23) |
| **License** | MIT |
| **Platforms** | macOS, iOS, tvOS, watchOS, visionOS |
| **Apple Silicon** | Wraps `UserDefaults` |
| **Verified** | 2026-08-12 |

---

## What it is

A type-safe wrapper over `UserDefaults`. Keys are declared once with a type and a default value,
then read and written without string lookups or optional unwrapping. It supports `Codable`
values, SwiftUI observation, and change observation with async sequences.

```swift
// Declare once
extension Defaults.Keys {
    static let httpsFirstEnabled = Key<Bool>("httpsFirstEnabled", default: true)
    static let hibernationDelay  = Key<TimeInterval>("hibernationDelay", default: 300)
}

// Use anywhere — no strings, no optionals, no casting
Defaults[.httpsFirstEnabled] = false
```

## Why it matters for Qwave

It raises a question worth asking regardless of the answer: **should `SettingsStore` be SQLite?**

`Persistence/SettingsStore.swift` stores preferences in the same SQLite database as history,
bookmarks, and sessions. That is unusual — most Mac apps use `UserDefaults` for preferences.

| | SQLite `SettingsStore` (today) | `UserDefaults` + Defaults |
|--|-------------------------------|---------------------------|
| Type safety | Hand-rolled | Compile-time |
| Observation | Manual | Built-in, SwiftUI-aware |
| System integration | None | `defaults` CLI, MDM, config profiles |
| Portability | One file, easy to export | Scattered in the defaults domain |
| Sovereignty | Everything in one auditable file | Preferences in a system-managed store |

The SQLite choice is **defensible on sovereignty grounds** — a single file the user can inspect,
back up, or delete, versus a plist the system manages and syncs on its own schedule. For a
browser whose premise is user control over their own data, that is a real argument.

Where Defaults clearly fits is the **UI-state layer** that should not live in the sovereign
data file at all: window frames, sidebar widths, last-selected Settings pane, tab bar
appearance. That state is ephemeral, uninteresting, and does not belong in the same store as
browsing history.

```swift
// Ephemeral UI state → UserDefaults; user data → SQLite
extension Defaults.Keys {
    static let settingsSelectedPane = Key<String>("settingsSelectedPane", default: "shields")
    static let libraryWindowFrame   = Key<String>("libraryWindowFrame",   default: "")
    static let tabBarShowsFavicons  = Key<Bool>("tabBarShowsFavicons",    default: true)
}
```

That split is clean, defensible, and easy to explain to a privacy-conscious user: *your data is
in one file you control; your window positions are not your data.*

## Apple Silicon notes

None — a thin wrapper over `UserDefaults`, which is `CFPreferences` underneath. No architecture
relevance.

## Adoption sketch

```swift
.package(url: "https://github.com/sindresorhus/Defaults", from: "9.0.9")
```

Introduce it for UI state only, and write the boundary down where the code can see it:

```
UserDefaults (via Defaults)     window frames · pane selection · view options
SQLite (SettingsStore)          shields policy · containers · VPN config · anything user-visible as data
```

If [KeyboardShortcuts](keyboard-shortcuts.md) is adopted, note that it persists to
`UserDefaults` itself — so shortcut bindings land on the UI-state side by default. That is a
reasonable outcome, but it should be a decision rather than a discovery.

## Risks

- **Two settings systems.** The split must be documented and enforced, or it erodes into "wherever
  was convenient".
- **9.0.9 widened the swift-syntax dependency** — a macro-based package, so it carries
  compile-time cost and swift-syntax version coupling.
- **`UserDefaults` is less sovereign.** System-managed, potentially synced, not obviously
  user-inspectable. Keep genuine user data out of it — that is the entire point of the split.
- **Third-party dependency for a thin wrapper.** `UserDefaults` with a small hand-rolled typed-key
  helper covers most of this in about 30 lines. Weigh that seriously.

## Verdict

🔵 **Trial — for UI state only, not for user data.**

The type-safe wrapper is genuinely better than raw `UserDefaults`, and separating ephemeral UI
state from sovereign user data is a good architectural decision independent of which package
implements it.

**Keep `SettingsStore` on SQLite.** Its unusual choice is the right one for a browser whose pitch
is that your data lives in one file you control. Defaults handles the window frames — which
nobody needs to control.

Given how small the wrapper is, a hand-rolled typed-key helper is a legitimate alternative worth
comparing before taking the dependency.
