import XCTest
@testable import BrowserCore

@MainActor
final class HibernationControllerTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    private func info(
        id: UUID = UUID(),
        selected: Bool = false,
        pinned: Bool = false,
        media: Bool = false,
        hibernatable: Bool = true,
        loading: Bool = false,
        idleFor: TimeInterval
    ) -> TabHibernationInfo {
        TabHibernationInfo(
            id: id,
            isSelected: selected,
            isPinned: pinned,
            isPlayingMedia: media,
            isHibernatable: hibernatable,
            lastActivated: epoch.addingTimeInterval(-idleFor),
            isLoading: loading
        )
    }

    func testIdleBackgroundTabHibernates() {
        let controller = HibernationController(timeout: 900)
        let stale = info(idleFor: 1000)
        let fresh = info(idleFor: 100)
        let result = controller.tabsToHibernate(now: epoch, tabs: [stale, fresh])
        XCTAssertEqual(result, [stale.id])
    }

    func testSelectedTabNeverHibernates() {
        let controller = HibernationController(timeout: 900)
        let selected = info(selected: true, idleFor: 10_000)
        XCTAssertTrue(controller.tabsToHibernate(now: epoch, tabs: [selected]).isEmpty)
    }

    func testPinnedTabNeverHibernates() {
        let controller = HibernationController(timeout: 900)
        let pinned = info(pinned: true, idleFor: 10_000)
        XCTAssertTrue(controller.tabsToHibernate(now: epoch, tabs: [pinned]).isEmpty)
    }

    func testMediaTabNeverHibernates() {
        let controller = HibernationController(timeout: 900)
        let media = info(media: true, idleFor: 10_000)
        XCTAssertTrue(controller.tabsToHibernate(now: epoch, tabs: [media]).isEmpty)
    }

    func testNonHibernatableTabSkipped() {
        let controller = HibernationController(timeout: 900)
        let alreadyDone = info(hibernatable: false, idleFor: 10_000)
        XCTAssertTrue(controller.tabsToHibernate(now: epoch, tabs: [alreadyDone]).isEmpty)
    }

    func testExactTimeoutBoundaryHibernates() {
        let controller = HibernationController(timeout: 900)
        let boundary = info(idleFor: 900)
        XCTAssertEqual(controller.tabsToHibernate(now: epoch, tabs: [boundary]), [boundary.id])
    }

    func testTimeoutUpdateTakesEffect() {
        let controller = HibernationController(timeout: 900)
        let tab = info(idleFor: 300)
        XCTAssertTrue(controller.tabsToHibernate(now: epoch, tabs: [tab]).isEmpty)
        controller.updateTimeout(60)
        XCTAssertEqual(controller.tabsToHibernate(now: epoch, tabs: [tab]), [tab.id])
    }

    // MARK: - Energy-tick yield (Speedometer fix, suspect #2)

    /// A long-idle background tab that is mid-load must NOT be snapshotted:
    /// hibernating it would lose in-flight state and cost a foreground pause.
    func testLoadingBackgroundTabNeverHibernates() {
        let controller = HibernationController(timeout: 900)
        let loading = info(loading: true, idleFor: 10_000)
        XCTAssertTrue(controller.tabsToHibernate(now: epoch, tabs: [loading]).isEmpty)
    }

    /// While the visible tab is loading, the whole tick yields — even a
    /// stale, idle, otherwise-hibernatable background tab is left alone so no
    /// teardown snapshot competes with the foreground page load.
    func testForegroundLoadingYieldsWholeTick() {
        let controller = HibernationController(timeout: 900)
        let stale = info(idleFor: 10_000)
        let result = controller.tabsToHibernate(
            now: epoch, tabs: [stale], foregroundIsLoading: true)
        XCTAssertTrue(result.isEmpty)
    }

    /// The yield is a deferral, not a shutdown: the SAME stale tab hibernates on
    /// the next tick once the foreground finishes loading. This is the guarantee
    /// that the battery story survives the benchmark fix.
    func testTicksResumeWhenIdle() {
        let controller = HibernationController(timeout: 900)
        let stale = info(idleFor: 10_000)
        XCTAssertTrue(
            controller.tabsToHibernate(now: epoch, tabs: [stale], foregroundIsLoading: true).isEmpty,
            "should yield while foreground loads")
        XCTAssertEqual(
            controller.tabsToHibernate(now: epoch, tabs: [stale], foregroundIsLoading: false),
            [stale.id],
            "should hibernate once foreground is idle")
    }
}
