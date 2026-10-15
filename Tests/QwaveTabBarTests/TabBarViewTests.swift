import AppKit
import XCTest

final class TabBarViewTests: XCTestCase {
    @MainActor
    func testFirstTabAndSubsequentInsertion() {
        let bar = TabBarView(frame: .zero)
        let first = model("First")
        let second = model("Second")

        // The first insertion used to raise NSInternalInconsistencyException
        // because the new view was removed from a stack it hadn't joined.
        bar.update(tabs: [first], selectedID: first.id)
        let firstView = tabViews(bar)[0]
        XCTAssertEqual(tabViews(bar).count, 1)

        bar.update(tabs: [first, second], selectedID: second.id)
        XCTAssertEqual(tabViews(bar).count, 2)
        XCTAssertTrue(tabViews(bar)[0] === firstView)
    }

    @MainActor
    func testReorderingReusesViewsAndClosingRemovesOnlyClosedTabs() {
        let bar = TabBarView(frame: .zero)
        let first = model("First")
        let second = model("Second")
        bar.update(tabs: [first, second], selectedID: first.id)
        let original = tabViews(bar)

        bar.update(tabs: [second, first], selectedID: second.id)
        XCTAssertTrue(tabViews(bar)[0] === original[1])
        XCTAssertTrue(tabViews(bar)[1] === original[0])

        bar.update(tabs: [first], selectedID: first.id)
        XCTAssertEqual(tabViews(bar).count, 1)
        XCTAssertTrue(tabViews(bar)[0] === original[0])
        XCTAssertNil(original[1].superview)

        bar.update(tabs: [], selectedID: nil)
        XCTAssertTrue(tabViews(bar).isEmpty)
        bar.update(tabs: [second], selectedID: second.id)
        XCTAssertEqual(tabViews(bar).count, 1)
    }

    @MainActor
    private func tabViews(_ bar: TabBarView) -> [NSView] {
        // The last accessibility child is the persistent New Tab button.
        Array((bar.accessibilityChildren() ?? []).dropLast()).compactMap { $0 as? NSView }
    }

    private func model(_ title: String) -> TabDisplayModel {
        TabDisplayModel(
            id: UUID(), title: title, isPinned: false, isHibernated: false,
            isLoading: false, isEphemeral: false, containerColorHex: nil, favicon: nil)
    }
}
