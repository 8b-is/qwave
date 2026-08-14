# The cheapest optimization is a boring OS integration: App Intents and Spotlight in a WebKit browser

> Draft — not published, not reviewed, not final. Status: draft. Target: — (long-form).
> Session: 2026-08-14, Apple Silicon (M-series), Xcode 16.4 pinned (CI), local
> toolchain Xcode 26.4.1 for compile checks.

## The claim

Qwave is a WebKit-native browser whose headline work is invisible: allocation
counts on the keystroke path, hibernation reclaim in out-of-process WebContent
processes, a 59,657-rule blocklist that compiles in 2.84 s. Users never see any
of it. What they *do* see is whether the browser feels native — and on macOS,
"native" increasingly means "shows up in the places the OS already is":
Command+Space, Shortcuts, Siri. A browser that isn't in Spotlight is a browser
that doesn't exist for a chunk of its users.

This draft documents the two first integrations shipped in this direction,
the *trick* that makes them cheap (zero-config system discovery, no Info.plist
keys, no new entitlements), and the sharp edges Swift 6 strict concurrency
added to what should have been an afternoon of glue code.

## The features

1. **App Intents / Shortcuts** — five intents: Open URL, New Tab, Toggle
   Shields for a site, Connect VPN, Disconnect VPN. All discoverable by the
   Shortcuts app automatically.
2. **CoreSpotlight** — bookmarks indexed so they're one Command+Space away.
   Live indexing on add, a delete-all + re-add sweep at launch so entries for
   deleted bookmarks don't rot.

Both land as two new files plus two small hooks. Total: ~330 lines of Swift.

## The trick: zero-config discovery

The expensive-looking part of OS integration is usually *plumbing*: Info.plist
keys, entitlements, extensions, provisioning. For these two features, none of
that exists.

**App Intents are auto-discovered.** On macOS 13+, a type conforming to
`AppIntent` inside the app target is picked up by the system when the app is
installed. No `INIntentsSupported`, no URL scheme, no `NSUserActivityTypes`.
The `AppShortcutsProvider` type additionally registers phrases with the
Shortcuts app:

```swift
struct QwaveAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenURLIntent(),
            phrases: [
                // Two build-time rules: every phrase interpolates
                // \(.applicationName) exactly once, and only AppEntity/AppEnum
                // parameters may be interpolated — so the URL parameter stays
                // out of the phrase and Siri asks for it via
                // requestValueDialog.
                "Open a URL in \(.applicationName)",
                "Open a web address in \(.applicationName)",
            ],
            shortTitle: "Open in Qwave",
            systemImageName: "globe"
        )
        // ...
    }
}
```

**CoreSpotlight needs no entitlement for on-device indexing.** The iCloud
sync entitlement is only required if you want the index to roam across
devices. `CSSearchableIndex.default()` against a local index is plain app
code:

```swift
enum SpotlightIndexer {
    static let domainIdentifier = "is.8b.qwave.bookmarks"

    @MainActor
    static func index(_ bookmark: Bookmark) async {
        do {
            try await CSSearchableIndex.default().indexSearchableItems([item(for: bookmark)])
        } catch {
            QwaveLog.browser.info("Spotlight: failed to index bookmark '\(bookmark.title, privacy: .public)'")
        }
    }

    private static func item(for bookmark: Bookmark) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .url)
        attributes.title = bookmark.title
        attributes.contentURL = bookmark.url
        return CSSearchableItem(
            uniqueIdentifier: "bookmark-\(bookmark.id)",
            domainIdentifier: domainIdentifier,
            attributeSet: attributes
        )
    }
}
```

The launch sweep is the maintenance half — it is what deletes entries for
bookmarks removed while the app was closed:

```swift
@MainActor
static func reindexAll(_ bookmarks: [Bookmark]) async {
    let index = CSSearchableIndex.default()
    do {
        try await index.deleteAllSearchableItems()
        try await index.indexSearchableItems(bookmarks.map(item(for:)))
    } catch {
        QwaveLog.browser.info("Spotlight: launch reindex failed (\(String(describing: error)))")
    }
}
```

Delete-all + re-add is not free, so it runs once per launch, not per change.
New bookmarks are indexed individually at creation.

## Bridging into a @MainActor service graph

The hard part in Swift 6 is not the OS APIs, it's the app's own architecture.
Qwave's service graph (`BrowserEnvironment`) is `@MainActor`-isolated, built
asynchronously at launch, and reachable only through the AppDelegate. An
`AppIntent` runs inside the app process (launching it if needed), but it must
not assume the environment exists yet. The bridge is an enum that knows how to
wait-or-fail, and a guard that produces a user-readable error instead of a
crash:

```swift
@MainActor
enum QwaveIntentHost {
    static var delegate: AppDelegate? {
        NSApp.delegate as? AppDelegate
    }

    static func requireEnvironment() throws -> BrowserEnvironment {
        guard let environment = delegate?.environment else {
            throw QwaveIntentError.appNotReady
        }
        return environment
    }

    static func open(url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw QwaveIntentError.unsupportedURL
        }
        let window = delegate?.frontmostBrowserWindow ?? delegate?.openWindow()
        window?.openNewTab(url: url)
    }
}
```

`QwaveIntentError` conforms to `CustomLocalizedStringResourceConvertible`, so
the failure text the user sees in Shortcuts is a localized resource, not an
exception dump.

The same pattern — poll briefly for the environment instead of racing it —
applies to the launch-time Spotlight sweep:

```swift
private func reindexWhenReady() async {
    let delegate = NSApp.delegate as? AppDelegate
    var attempts = 0
    while delegate?.environment?.bookmarks == nil, attempts < 50 {
        try? await Task.sleep(for: .milliseconds(100))
        attempts += 1
    }
    guard let bookmarks = delegate?.environment?.bookmarks else { return }
    do {
        let all = try await bookmarks.all()
        await SpotlightIndexer.reindexAll(all)
    } catch {
        QwaveLog.browser.info("Spotlight: launch reindex failed (\(String(describing: error)))")
    }
}
```

## Sharp edges, learned the hard way

Three Swift 6 / framework gotchas cost more time than the features themselves.
All three are compiler-visible, so none of them can silently regress later:

1. **`LocalizedStringResource` does not like string concatenation.** Its
   `ExpressibleByStringLiteral` conformance goes through
   `String.LocalizationValue`, and a `"..." + "..."` expression produces a
   plain `String` that the `IntentDescription` initializer refuses. The
   compiler error reads `cannot convert value of type 'String' to expected
   argument type 'LocalizedStringResource'` at the `+`. Fix: one literal per
   description, no concatenation.

2. **`static let title: LocalizedStringResource = "..."` can silently pick
   `String`.** Same coercion quirk one level up: on `static let` properties
   the literal sometimes resolves to `String` even with the explicit type
   annotation. The robust spelling is
   `static let title = LocalizedStringResource("...")`.

3. **Optional-chained async calls need `await` spelled differently.**
   `self?.reindexWhenReady()` inside a `Task` fails with *"expression is
   'async' but is not marked with 'await'"* — the optional chain hides the
   await point. Write it as `guard let self else { return }; await
   self.reindexWhenReady()`.

4. **Observer lifetime.** The launch sweep registers a
   `didFinishLaunchingNotification` observer. With block-based
   `NotificationCenter` APIs, the returned token's deallocation removes the
   observer — a discarded temporary (`_ = SpotlightLaunchSync()`) registers
   and immediately unregisters. The instance must be kept alive for the
   process lifetime, so it is stored in a file-scope global in `main.swift`:

   ```swift
   /// File-scope globals are never released, so the observer survives.
   let spotlightLaunchSync = SpotlightLaunchSync()
   ```

## What we verified, and what we did not

Verified in-session:

- Whole app target typechecks clean under Swift 6 strict concurrency
  (including the two new files).
- `swift-format lint --strict` clean against the repo config.
- QwaveKit suite: 256 tests, 0 failures (release-mode run; the debug run is
  dominated by the Classic McEliece keygen vectors — 126 s for one test at
  `-Onone` — which is why CI's threshold discipline exists).

Not verified yet (honest gaps):

- End-user Shortcuts/Siri UX — requires a signed build installed in
  `/Applications`; unsigned CI artifacts don't surface to the Shortcuts app.
- Spotlight result rendering — needs a real bookmark store populated and
  `mdls`/`mdfind` inspection on a dev machine.

## Follow-ups

- `qwave://` URL scheme + Apple Events (`open qwave://...`) — needs one
  Info.plist key in `project.yml` (XcodeGen is the source of truth; no
  hand-edits).
- Share the current URL via `NSSharingService` in the window menu.
- WidgetKit quick-launch widget — needs an app-group entitlement and a second
  target; larger surface, deferred.
- Handoff (`NSUserActivity`) — partial value without an iOS companion app;
  parked.
