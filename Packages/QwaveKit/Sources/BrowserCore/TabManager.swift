import Foundation
import OrderedCollections

/// Ordered tab collection for one window, with selection. Pure model — the
/// window controller observes `onChange` and re-renders.
///
/// Storage is an `OrderedDictionary`: the tab strip needs ordered + unique +
/// O(1) keyed lookup, which an array gives up (O(n) scans) and an
/// array-plus-index pair only gives via a hand-synchronised invariant.
@MainActor
public final class TabManager {
    private var storage: OrderedDictionary<UUID, Tab> = [:]
    public private(set) var selectedTabID: UUID?

    /// Fired after any mutation (add/close/select/move).
    public var onChange: (() -> Void)?
    /// Fired just before a tab is removed so owners can tear down web views.
    public var onTabClosed: ((Tab) -> Void)?

    public init() {}

    public var tabs: [Tab] {
        Array(storage.values)
    }

    public var selectedTab: Tab? {
        selectedTabID.flatMap { storage[$0] }
    }

    public var selectedIndex: Int? {
        selectedTabID.flatMap { storage.index(forKey: $0) }
    }

    public func tab(withID id: UUID) -> Tab? {
        storage[id]
    }

    // MARK: - Mutations

    /// Appends a tab (pinned tabs cluster at the front) and optionally selects it.
    public func append(_ tab: Tab, select: Bool = true) {
        if tab.isPinned {
            let insertIndex = storage.values.lastIndex(where: { $0.isPinned }).map { $0 + 1 } ?? 0
            storage.updateValue(tab, forKey: tab.id, insertingAt: insertIndex)
        } else {
            storage[tab.id] = tab
        }
        if select {
            selectedTabID = tab.id
            tab.noteActivated()
        }
        onChange?()
    }

    /// Inserts immediately after the currently selected tab (Cmd-click flow).
    public func insertAfterSelection(_ tab: Tab, select: Bool) {
        if let index = selectedIndex {
            storage.updateValue(tab, forKey: tab.id, insertingAt: index + 1)
        } else {
            storage[tab.id] = tab
        }
        if select {
            selectedTabID = tab.id
            tab.noteActivated()
        }
        onChange?()
    }

    public func select(tabID: UUID) {
        guard selectedTabID != tabID, let tab = storage[tabID] else { return }
        selectedTabID = tabID
        tab.noteActivated()
        onChange?()
    }

    public func selectNext() {
        guard let index = selectedIndex, !storage.isEmpty else { return }
        select(tabID: storage.elements[(index + 1) % storage.count].key)
    }

    public func selectPrevious() {
        guard let index = selectedIndex, !storage.isEmpty else { return }
        select(tabID: storage.elements[(index - 1 + storage.count) % storage.count].key)
    }

    /// Closes a tab; selection moves to the nearest neighbor.
    public func close(tabID: UUID) {
        guard let index = storage.index(forKey: tabID) else { return }
        let closing = storage.elements[index].value
        storage.removeValue(forKey: tabID)

        if selectedTabID == tabID {
            if storage.isEmpty {
                selectedTabID = nil
            } else {
                let neighbor = storage.elements[min(index, storage.count - 1)].value
                selectedTabID = neighbor.id
                neighbor.noteActivated()
            }
        }
        onTabClosed?(closing)
        onChange?()
    }

    public func move(fromIndex: Int, toIndex: Int) {
        guard storage.elements.indices.contains(fromIndex),
            storage.elements.indices.contains(toIndex),
            fromIndex != toIndex
        else {
            return
        }
        // OrderedDictionary.move's destination is in the ORIGINAL index
        // space ("insert before"); the public API keeps the historical
        // remove-then-insert semantics.
        storage.move(indices: [fromIndex], to: toIndex > fromIndex ? toIndex + 1 : toIndex)
        onChange?()
    }

    public var isEmpty: Bool { storage.isEmpty }
    public var count: Int { storage.count }
}
