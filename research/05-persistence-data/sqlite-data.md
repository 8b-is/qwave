# SQLiteData (`pointfreeco/sqlite-data`)

| | |
|---|---|
| **Repo** | https://github.com/pointfreeco/sqlite-data |
| **Version** | **1.10.0** (Aug 11) |
| **License** | MIT |
| **Platforms** | macOS, iOS, tvOS, watchOS |
| **Built on** | [GRDB](grdb.md) + [swift-structured-queries](swift-structured-queries.md) |
| **Apple Silicon** | Inherited from GRDB / system SQLite |
| **Verified** | 2026-08-12 |

---

## What it is

Point-Free's replacement for SwiftData: a fast, lightweight persistence layer powered by SQL,
with CloudKit synchronisation, built on top of GRDB. It offers analogues of SwiftData's
`@Model`, `@Query`, and `#Predicate` — but tuned for **direct access to the underlying
database** rather than an opaque object graph.

It was formerly called SharingGRDB. The motivation is widely shared: SwiftData has rough edges
and has not received much investment since launch, while GRDB is battle-tested. SQLiteData
puts a modern declarative API on the reliable foundation.

Development is brisk — 1.10.0 landed record observation improvements, fetching refinements, and
typed decoding work.

## Why it matters for Qwave

It is the **ergonomic layer** over the [GRDB](grdb.md) adoption, and the value is concentrated
in SwiftUI:

```swift
// A Settings pane or the Library window, staying live automatically
@FetchAll(HistoryEntry.order(by: \.visitedAt).limit(200))
var recentHistory: [HistoryEntry]
```

`QwaveApp/SettingsWindow/*` and `LibraryWindow.swift` are SwiftUI, so this maps onto real code.

But two things make it a poorer fit for Qwave specifically than it would be for a typical app:

**1. CloudKit sync is the headline feature, and Qwave should not want it.** Syncing browser
history to iCloud is precisely the behaviour a sovereign browser exists to avoid. The feature is
optional, but adopting a library for a capability you must deliberately disable is weak
justification.

**2. Qwave is an AppKit shell.** The web content, tab management, and browser core are AppKit
and plain Swift. SwiftUI is confined to the Settings and Library windows. SQLiteData's value is
highest where SwiftUI is the primary UI — which describes a smaller share of Qwave than of most
apps.

## Apple Silicon notes

Nothing beyond [GRDB](grdb.md) — same system SQLite, same characteristics. The macro-based API
adds compile-time cost, mitigated by Swift 6.2's prebuilt swift-syntax support (see
[PLATFORM-BASELINE.md](../PLATFORM-BASELINE.md)).

## Adoption sketch

Only after GRDB is in and settled:

```swift
.package(url: "https://github.com/pointfreeco/sqlite-data", from: "1.10.0")
```

```swift
// LibraryWindow.swift — declarative, live, no observation plumbing
struct HistoryList: View {
    @FetchAll(HistoryEntry.order(by: \.visitedAt).limit(200))
    var entries: [HistoryEntry]

    var body: some View {
        List(entries) { HistoryRow(entry: $0) }
    }
}
```

Because it sits on GRDB, adoption is additive rather than a second migration — the same database
and the same records, with a nicer SwiftUI-facing API.

## Risks

- **CloudKit sync must stay off, deliberately and verifiably.** Add a test asserting no CloudKit
  container is configured. This is a sovereignty guarantee, not a preference.
- **Fast-moving.** 1.10.0 in August with feature work in point releases. Stable in the semver
  sense, active in practice.
- **Macro-based API.** Compile-time cost and occasionally cryptic diagnostics.
- **A layer on a layer.** GRDB plus structured-queries plus SQLiteData is three dependencies to
  audit where one would do. For a browser counting its trust boundary, that matters.
- **Lower leverage in an AppKit app.** The SwiftUI property wrappers are the product; Qwave's
  SwiftUI surface is two windows.

## Verdict

🟡 **Assess — revisit after GRDB has settled.**

Genuinely good work by a team with a strong track record, and the right answer for a
SwiftUI-first app that wants SwiftData's ergonomics without SwiftData's problems.

For Qwave the case is weaker: the flagship feature (CloudKit sync) is one the product must
refuse, the SwiftUI surface is small, and it triples the dependency count in the module that
touches user data. [GRDB](grdb.md) alone captures most of the value — including
`ValueObservation`, which is the live-UI feature that actually matters here.

**Revisit if** the SwiftUI surface grows substantially, or if `@FetchAll`-style ergonomics prove
to remove meaningful boilerplate once GRDB is in place.
