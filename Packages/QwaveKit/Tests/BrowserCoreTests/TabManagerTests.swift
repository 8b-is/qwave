import XCTest
@testable import BrowserCore

@MainActor
final class TabManagerTests: XCTestCase {
    func testAppendSelects() {
        let manager = TabManager()
        let tab = Tab()
        manager.append(tab)
        XCTAssertEqual(manager.selectedTabID, tab.id)
        XCTAssertEqual(manager.count, 1)
    }

    func testAppendWithoutSelecting() {
        let manager = TabManager()
        let first = Tab()
        let second = Tab()
        manager.append(first)
        manager.append(second, select: false)
        XCTAssertEqual(manager.selectedTabID, first.id)
        XCTAssertEqual(manager.tabs.map(\.id), [first.id, second.id])
    }

    func testPinnedTabsClusterAtFront() {
        let manager = TabManager()
        let normal = Tab()
        manager.append(normal)
        let pinned = Tab()
        pinned.isPinned = true
        manager.append(pinned, select: false)
        XCTAssertEqual(manager.tabs.map(\.id), [pinned.id, normal.id])
    }

    func testInsertAfterSelection() {
        let manager = TabManager()
        let a = Tab(); let b = Tab(); let c = Tab()
        manager.append(a)
        manager.append(b, select: false)
        manager.select(tabID: a.id)
        manager.insertAfterSelection(c, select: false)
        XCTAssertEqual(manager.tabs.map(\.id), [a.id, c.id, b.id])
    }

    func testCloseSelectedMovesToNeighbor() {
        let manager = TabManager()
        let a = Tab(); let b = Tab(); let c = Tab()
        manager.append(a)
        manager.append(b)
        manager.append(c, select: false)
        // selection is on b (index 1)
        manager.close(tabID: b.id)
        XCTAssertEqual(manager.selectedTabID, c.id, "closing selected selects the tab that took its index")
        XCTAssertEqual(manager.count, 2)
    }

    func testCloseLastSelectsPrevious() {
        let manager = TabManager()
        let a = Tab(); let b = Tab()
        manager.append(a)
        manager.append(b)
        manager.close(tabID: b.id)
        XCTAssertEqual(manager.selectedTabID, a.id)
    }

    func testCloseUnselectedKeepsSelection() {
        let manager = TabManager()
        let a = Tab(); let b = Tab()
        manager.append(a)
        manager.append(b, select: false)
        manager.close(tabID: b.id)
        XCTAssertEqual(manager.selectedTabID, a.id)
    }

    func testCloseFinalTabEmptiesSelection() {
        let manager = TabManager()
        let a = Tab()
        manager.append(a)
        manager.close(tabID: a.id)
        XCTAssertNil(manager.selectedTabID)
        XCTAssertTrue(manager.isEmpty)
    }

    func testSelectNextAndPreviousWrap() {
        let manager = TabManager()
        let a = Tab(); let b = Tab(); let c = Tab()
        manager.append(a)
        manager.append(b, select: false)
        manager.append(c, select: false)
        manager.select(tabID: c.id)
        manager.selectNext()
        XCTAssertEqual(manager.selectedTabID, a.id)
        manager.selectPrevious()
        XCTAssertEqual(manager.selectedTabID, c.id)
    }

    func testMove() {
        let manager = TabManager()
        let a = Tab(); let b = Tab(); let c = Tab()
        manager.append(a)
        manager.append(b, select: false)
        manager.append(c, select: false)
        manager.move(fromIndex: 0, toIndex: 2)
        XCTAssertEqual(manager.tabs.map(\.id), [b.id, c.id, a.id])
    }

    // MARK: - Reopen closed tab (⇧⌘T)

    func testReopenRestoresClosedTab() {
        let manager = TabManager()
        let a = Tab(pendingURL: URL(string: "https://a.example/"))
        let b = Tab(pendingURL: URL(string: "https://b.example/"))
        b.title = "Bee"
        b.isPinned = true
        b.pendingInteractionState = Data([1, 2, 3])
        manager.append(a)
        manager.append(b, select: false)

        XCTAssertFalse(manager.canReopenClosedTab)
        manager.close(tabID: b.id)
        XCTAssertTrue(manager.canReopenClosedTab)

        let reopened = manager.reopenLastClosedTab()
        XCTAssertNotNil(reopened)
        XCTAssertEqual(reopened?.url, URL(string: "https://b.example/"))
        XCTAssertEqual(reopened?.title, "Bee")
        XCTAssertEqual(reopened?.isPinned, true)
        XCTAssertEqual(reopened?.pendingInteractionState, Data([1, 2, 3]))
        XCTAssertEqual(manager.selectedTabID, reopened?.id, "reopened tab is selected")
        XCTAssertFalse(manager.canReopenClosedTab, "the record is consumed")
    }

    func testReopenRestoresOriginalIndex() {
        let manager = TabManager()
        let a = Tab(); let b = Tab(); let c = Tab()
        manager.append(a)
        manager.append(b, select: false)
        manager.append(c, select: false)
        manager.close(tabID: b.id)  // index 1
        let reopened = manager.reopenLastClosedTab()!
        XCTAssertEqual(manager.tabs.map(\.id), [a.id, reopened.id, c.id])
    }

    func testEphemeralTabsAreNotRecorded() {
        let manager = TabManager()
        let a = Tab(pendingURL: URL(string: "https://a.example/"))
        let burner = Tab(isEphemeral: true, pendingURL: URL(string: "https://secret.example/"))
        manager.append(a)
        manager.append(burner, select: false)
        manager.close(tabID: burner.id)
        XCTAssertFalse(manager.canReopenClosedTab, "ephemeral/private tabs never resurrect")
        XCTAssertNil(manager.reopenLastClosedTab())
    }

    func testReopenIsLIFOAndBounded() {
        let manager = TabManager()
        // Close 12 tabs; the ring keeps the 10 most recent.
        var ids: [UUID] = []
        for i in 0..<12 {
            let tab = Tab(pendingURL: URL(string: "https://\(i).example/"))
            manager.append(tab)
            ids.append(tab.id)
        }
        for id in ids { manager.close(tabID: id) }
        // Most recently closed comes back first.
        XCTAssertEqual(manager.reopenLastClosedTab()?.url, URL(string: "https://11.example/"))
        XCTAssertEqual(manager.reopenLastClosedTab()?.url, URL(string: "https://10.example/"))
        // Cap is 10: the two oldest (0, 1) were evicted, so only 8 remain.
        for _ in 0..<8 { XCTAssertNotNil(manager.reopenLastClosedTab()) }
        XCTAssertFalse(manager.canReopenClosedTab)
        XCTAssertNil(manager.reopenLastClosedTab())
    }

    func testReopenWithNothingClosedReturnsNil() {
        let manager = TabManager()
        manager.append(Tab())
        XCTAssertNil(manager.reopenLastClosedTab())
    }

    func testCallbacksFire() {
        let manager = TabManager()
        var changes = 0
        var closed: [UUID] = []
        manager.onChange = { changes += 1 }
        manager.onTabClosed = { closed.append($0.id) }

        let tab = Tab()
        manager.append(tab)
        manager.close(tabID: tab.id)
        XCTAssertEqual(changes, 2)
        XCTAssertEqual(closed, [tab.id])
    }
}
