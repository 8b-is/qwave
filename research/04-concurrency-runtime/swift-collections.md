# swift-collections (`apple/swift-collections`)

| | |
|---|---|
| **Repo** | https://github.com/apple/swift-collections |
| **Version** | **1.6.0** (Jun 8) |
| **License** | Apache 2.0 |
| **Platforms** | All Swift platforms |
| **Apple Silicon** | Pure Swift; no architecture-specific code |
| **Verified** | 2026-08-12 |

---

## What it is

Apple's package of data structures the standard library does not ship: `OrderedSet`,
`OrderedDictionary`, `Deque`, `Heap`, `BitSet`, `TreeSet`/`TreeDictionary` (persistent,
structure-sharing), and more.

The 1.6.0 release added ordered-collection mutation operations — `moveSubrange(_:to:)`,
`move(members:to:)`, and `move(indices:to:)` on both `OrderedSet` and `OrderedDictionary` —
alongside B-tree node capacity fixes and ownership-aware container types.

Those `move` operations are not incidental here. **Reordering an ordered collection is exactly
what tab drag-and-drop is.**

## Why it matters for Qwave

The cleanest fit in this entire research folder.

### `TabManager` is an ordered collection with uniqueness

`BrowserCore/TabManager.swift` maintains tabs that are **ordered** (the tab bar's left-to-right
sequence) and **unique** (one entry per tab identity), with frequent lookup by identity —
`TabHibernator` waking a specific tab, `NavigationCoordinator` routing an event.

An array gives O(n) lookup. A dictionary loses order. Maintaining both is how bugs where the tab
bar and the tab model disagree get written.

`OrderedDictionary<TabID, Tab>` is precisely this shape: O(1) keyed lookup, preserved order,
and — as of 1.6.0 — first-class reordering.

```swift
// Before: two structures kept in sync by hand
private var tabs: [Tab]
private var index: [TabID: Int]        // invalidated on every insert/remove

// After: one structure, one invariant
private var tabs: OrderedDictionary<TabID, Tab>

func moveTab(_ id: TabID, to destination: Int) {
    guard let from = tabs.index(forKey: id) else { return }
    tabs.move(indices: IndexSet(integer: from), to: destination)   // 1.6.0
}
```

### `Deque` for navigation history

Back/forward history is a double-ended structure with a bounded length. `Deque` gives O(1) at
both ends; an `Array` gives O(n) removal from the front. `SessionRestorer` and
`NavigationCoordinator` both touch this.

### `BitSet` for shield policy

`ShieldsPolicy` tracks per-host boolean state. If that ever grows to many flags across many
hosts, `BitSet` is dramatically more compact than `Set<Enum>` — a real consideration for a
browser holding policy for thousands of visited hosts.

## Apple Silicon notes

No architecture-specific code, but the performance characteristics matter more on M-series than
they might elsewhere. Apple Silicon's memory bandwidth is generous and its cache hierarchy is
large; the win from these structures is **fewer allocations and better locality**, which is
exactly what the memory subsystem rewards.

For a browser whose defining feature is memory management, a data structure that stops
`TabManager` from maintaining a redundant index is directly on-thesis.

## Adoption sketch

```swift
// Packages/QwaveKit/Package.swift
.package(url: "https://github.com/apple/swift-collections", from: "1.6.0"),
// then, on the BrowserCore target:
.product(name: "Collections", package: "swift-collections")
```

Import the specific module rather than the umbrella to keep build times down:

```swift
import OrderedCollections   // not: import Collections
```

Migrate `TabManager` first. `TabManagerTests` already exists and covers ordering and lookup, so
the refactor is verifiable rather than hopeful.

## Risks

Genuinely few — this is the lowest-risk dependency in the folder.

- **Adds a dependency** where an array-plus-dictionary works today. Justified by removing a
  hand-maintained invariant, not by elegance.
- **Umbrella import cost.** `import Collections` pulls in everything. Import submodules.
- **API stability.** 1.x and Apache 2.0-licensed under Apple's maintenance. As safe as a
  third-party dependency gets.

## Verdict

🟢 **Adopt.**

Apple-maintained, source-stable, exactly matched to `TabManager`'s actual data shape, and the
1.6.0 reorder operations map one-to-one onto tab drag-and-drop. It replaces a hand-synchronised
array-plus-index with a single structure that cannot fall out of sync.

**Start with:** `OrderedDictionary` in `TabManager`, with `TabManagerTests` as the safety net.
`Deque` for navigation history is a natural follow-on.
