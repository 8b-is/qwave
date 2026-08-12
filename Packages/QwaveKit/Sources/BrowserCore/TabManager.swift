import Foundation

/// Ordered tab collection for one window, with selection. Pure model — the
/// window controller observes `onChange` and re-renders.
@MainActor
public final class TabManager {
    public private(set) var tabs: [Tab] = []
    public private(set) var selectedTabID: UUID?

    /// Fired after any mutation (add/close/select/move).
    public var onChange: (() -> Void)?
    /// Fired just before a tab is removed so owners can tear down web views.
    public var onTabClosed: ((Tab) -> Void)?

    public init() {}

    public var selectedTab: Tab? {
        guard let selectedTabID else { return nil }
        return tabs.first { $0.id == selectedTabID }
    }

    public var selectedIndex: Int? {
        guard let selectedTabID else { return nil }
        return tabs.firstIndex { $0.id == selectedTabID }
    }

    public func tab(withID id: UUID) -> Tab? {
        tabs.first { $0.id == id }
    }

    // MARK: - Mutations

    /// Appends a tab (pinned tabs cluster at the front) and optionally selects it.
    public func append(_ tab: Tab, select: Bool = true) {
        if tab.isPinned {
            let insertIndex = tabs.lastIndex(where: { $0.isPinned }).map { $0 + 1 } ?? 0
            tabs.insert(tab, at: insertIndex)
        } else {
            tabs.append(tab)
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
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
        if select {
            selectedTabID = tab.id
            tab.noteActivated()
        }
        onChange?()
    }

    public func select(tabID: UUID) {
        guard selectedTabID != tabID, let tab = tab(withID: tabID) else { return }
        selectedTabID = tabID
        tab.noteActivated()
        onChange?()
    }

    public func selectNext() {
        guard let index = selectedIndex, !tabs.isEmpty else { return }
        select(tabID: tabs[(index + 1) % tabs.count].id)
    }

    public func selectPrevious() {
        guard let index = selectedIndex, !tabs.isEmpty else { return }
        select(tabID: tabs[(index - 1 + tabs.count) % tabs.count].id)
    }

    /// Closes a tab; selection moves to the nearest neighbor.
    public func close(tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let closing = tabs[index]
        tabs.remove(at: index)

        if selectedTabID == tabID {
            if tabs.isEmpty {
                selectedTabID = nil
            } else {
                let neighbor = tabs[min(index, tabs.count - 1)]
                selectedTabID = neighbor.id
                neighbor.noteActivated()
            }
        }
        onTabClosed?(closing)
        onChange?()
    }

    public func move(fromIndex: Int, toIndex: Int) {
        guard tabs.indices.contains(fromIndex), tabs.indices.contains(toIndex), fromIndex != toIndex else {
            return
        }
        let tab = tabs.remove(at: fromIndex)
        tabs.insert(tab, at: toIndex)
        onChange?()
    }

    public var isEmpty: Bool { tabs.isEmpty }
    public var count: Int { tabs.count }
}
