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
