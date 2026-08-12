import XCTest
@testable import BrowserCore
import Persistence

@MainActor
final class SessionRestorerTests: XCTestCase {
    func testRoundTrip() {
        let manager = TabManager()
        let work = UUID()

        let first = Tab(pendingURL: URL(string: "https://example.com/"))
        first.title = "Example"
        first.isPinned = true
        manager.append(first)

        let second = Tab(containerID: work, pendingURL: URL(string: "https://webkit.org/"))
        second.title = "WebKit"
        manager.append(second)

        let snapshot = SessionRestorer.snapshot(of: [manager])
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows[0].tabs.count, 2)
        XCTAssertEqual(snapshot.windows[0].selectedIndex, 1)

        let restored = SessionRestorer.managers(from: snapshot)
        XCTAssertEqual(restored.count, 1)
        let restoredTabs = restored[0].tabs
        XCTAssertEqual(restoredTabs.count, 2)
        XCTAssertEqual(restoredTabs[0].pendingURL, URL(string: "https://example.com/"))
        XCTAssertTrue(restoredTabs[0].isPinned)
        XCTAssertEqual(restoredTabs[1].containerID, work)
        XCTAssertEqual(restored[0].selectedIndex, 1)
    }

    func testEphemeralTabsExcluded() {
        let manager = TabManager()
        manager.append(Tab(pendingURL: URL(string: "https://example.com/")))
        manager.append(Tab(containerID: ContainerRegistry.ephemeralProfileID, isEphemeral: true, pendingURL: URL(string: "https://secret.example/")))

        let snapshot = SessionRestorer.snapshot(of: [manager])
        XCTAssertEqual(snapshot.windows[0].tabs.count, 1)
        XCTAssertEqual(snapshot.windows[0].tabs[0].url, URL(string: "https://example.com/"))
    }

    func testWindowWithOnlyEphemeralTabsDropped() {
        let manager = TabManager()
        manager.append(Tab(isEphemeral: true))
        let snapshot = SessionRestorer.snapshot(of: [manager])
        XCTAssertTrue(snapshot.windows.isEmpty)
    }

    func testSelectedEphemeralFallsBackToFirstPersistable() {
        let manager = TabManager()
        manager.append(Tab(pendingURL: URL(string: "https://a.example/")))
        manager.append(Tab(isEphemeral: true))
        // selection on the ephemeral tab
        let snapshot = SessionRestorer.snapshot(of: [manager])
        XCTAssertEqual(snapshot.windows[0].selectedIndex, 0)
    }
}
