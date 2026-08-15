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

    /// Everything needed to bring a closed tab back exactly where it was.
    private struct ClosedTab {
        let containerID: UUID?
        let url: URL?
        let title: String
        let isPinned: Bool
        let interactionState: Data?
        let index: Int
    }

    /// Ring buffer of recently closed (non-ephemeral) tabs, oldest first.
    /// Powers Reopen Closed Tab (⇧⌘T).
    private var closedTabs: [ClosedTab] = []
    private let closedTabCapacity = 10

    /// Whether there is a closed tab to reopen.
    public var canReopenClosedTab: Bool { !closedTabs.isEmpty }

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
        recordClosedTab(closing, at: index)
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

    /// Snapshots a tab about to be closed into the reopen ring. Ephemeral
    /// (burner/private) tabs are never recorded — reopening one would defeat
    /// the point of a burner tab.
    private func recordClosedTab(_ tab: Tab, at index: Int) {
        guard !tab.isEphemeral else { return }
        closedTabs.append(
            ClosedTab(
                containerID: tab.containerID,
                url: tab.url ?? tab.hibernationRecord?.url ?? tab.pendingURL,
                title: tab.displayTitle,
                isPinned: tab.isPinned,
                interactionState: tab.webView?.interactionState as? Data
                    ?? tab.hibernationRecord?.interactionState
                    ?? tab.pendingInteractionState,
                index: index
            )
        )
        if closedTabs.count > closedTabCapacity {
            closedTabs.removeFirst(closedTabs.count - closedTabCapacity)
        }
    }

    /// Reopens the most recently closed tab at (approximately) its old
    /// position, carrying its full interaction state so back/forward + scroll
    /// come back. The web view is built lazily on selection by the owner.
    @discardableResult
    public func reopenLastClosedTab() -> Tab? {
        guard let record = closedTabs.popLast() else { return nil }
        let tab = Tab(containerID: record.containerID, pendingURL: record.url)
        tab.title = record.title
        tab.url = record.url
        tab.isPinned = record.isPinned
        tab.pendingInteractionState = record.interactionState
        let target = min(max(record.index, 0), storage.count)
        storage.updateValue(tab, forKey: tab.id, insertingAt: target)
        selectedTabID = tab.id
        tab.noteActivated()
        onChange?()
        return tab
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
