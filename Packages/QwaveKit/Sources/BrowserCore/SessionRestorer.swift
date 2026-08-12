import Foundation
import Persistence

/// Maps live tab state to/from `SessionSnapshot`s (Persistence). Ephemeral
/// tabs are dropped on save — burner tabs must not survive relaunch.
@MainActor
public enum SessionRestorer {
    public static func snapshot(of managers: [TabManager]) -> SessionSnapshot {
        let windows = managers.compactMap { manager -> WindowSnapshot? in
            let persistable = manager.tabs.filter { !$0.isEphemeral }
            guard !persistable.isEmpty else { return nil }

            let selectedID = manager.selectedTabID
            let selectedIndex = persistable.firstIndex { $0.id == selectedID } ?? 0
            let tabs = persistable.map { tab in
                TabSnapshot(
                    url: tab.url ?? tab.hibernationRecord?.url ?? tab.pendingURL,
                    title: tab.displayTitle,
                    containerID: tab.containerID,
                    isPinned: tab.isPinned
                )
            }
            return WindowSnapshot(tabs: tabs, selectedIndex: selectedIndex)
        }
        return SessionSnapshot(windows: windows)
    }

    /// Rebuilds tabs into fresh `TabManager`s. Tabs come back in the
    /// `.fresh` state carrying a pending URL — web views are built lazily on
    /// first selection, so restoring a 40-tab session doesn't spawn 40 web
    /// processes at launch.
    public static func managers(from snapshot: SessionSnapshot) -> [TabManager] {
        snapshot.windows.map { window in
            let manager = TabManager()
            for tabSnapshot in window.tabs {
                let tab = Tab(containerID: tabSnapshot.containerID, pendingURL: tabSnapshot.url)
                tab.title = tabSnapshot.title
                tab.url = tabSnapshot.url
                tab.isPinned = tabSnapshot.isPinned
                manager.append(tab, select: false)
            }
            if manager.tabs.indices.contains(window.selectedIndex) {
                manager.select(tabID: manager.tabs[window.selectedIndex].id)
            } else if let first = manager.tabs.first {
                manager.select(tabID: first.id)
            }
            return manager
        }
    }
}
