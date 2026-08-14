import WebKit
import XCTest

@testable import Shields

/// Counts the rule-list mutations ShieldsDirector.applyLists performs so we can
/// assert the redundant remove-all + re-add is elided when nothing changed.
private final class SpyContentController: WKUserContentController {
    private(set) var removeAllCount = 0
    private(set) var addCount = 0

    override func removeAllContentRuleLists() {
        removeAllCount += 1
        super.removeAllContentRuleLists()
    }

    override func add(_ contentRuleList: WKContentRuleList) {
        addCount += 1
        super.add(contentRuleList)
    }
}

@MainActor
final class ShieldsDirectorApplyTests: XCTestCase {
    private func director() -> ShieldsDirector {
        // No prepare(): both built-in lists are nil, so the resolved attachment
        // is the empty set — enough to exercise the cache's fast path without a
        // real (async, heavy) WKContentRuleList compile.
        ShieldsDirector(compiler: RuleListCompiler(store: nil), policy: ShieldsPolicy(directory: nil))
    }

    func testRepeatedApplyForSameHostReconcilesOnce() {
        let spy = SpyContentController()
        let director = director()
        director.applyLists(to: spy, forHost: "example.com")
        director.applyLists(to: spy, forHost: "example.com")
        director.applyLists(to: spy, forHost: "example.com")
        // Before the cache: 3 teardowns. After: only the first navigation
        // reconciles; the identical attachments short-circuit.
        XCTAssertEqual(spy.removeAllCount, 1, "redundant navigations must not re-tear-down the rule lists")
    }

    func testDistinctControllersEachGetTheirOwnReconcile() {
        let a = SpyContentController()
        let b = SpyContentController()
        let director = director()
        director.applyLists(to: a, forHost: "example.com")
        director.applyLists(to: b, forHost: "example.com")
        // The cache is per-controller: a fresh controller is never assumed to
        // already match another's attachment.
        XCTAssertEqual(a.removeAllCount, 1)
        XCTAssertEqual(b.removeAllCount, 1)
    }

    // MARK: - Launch gate (issue #19): shields never bypassed at cold start

    /// GUARANTEE test: a network navigation requested before the rule lists are
    /// ready must NOT proceed until they are reconciled onto its user-content
    /// controller — attach-before-load ordering.
    func testGatedNavigationDefersUntilReadyThenReconcilesFirst() {
        let director = director()  // not prepared → not ready
        XCTAssertFalse(director.isReady)
        let spy = SpyContentController()
        let proceeded = expectation(description: "navigation proceeds only after ready")
        director.applyListsThen(to: spy, forHost: "example.com") {
            // By the time the load is allowed, shields have been reconciled
            // (removeAll ran) — never allowed with shields on but unattached.
            XCTAssertEqual(spy.removeAllCount, 1, "lists must be reconciled before the load proceeds")
            proceeded.fulfill()
        }
        // Cold: the gate must be holding — nothing reconciled, nothing proceeded.
        XCTAssertEqual(spy.removeAllCount, 0, "must not touch the controller before ready")
        // Release the gate (as prepare() does when the compile finishes).
        director.markReady()
        wait(for: [proceeded], timeout: 2)
    }

    /// WIN / steady-state test: once ready, the gate adds no latency — the
    /// navigation is reconciled and allowed synchronously, so warm launches and
    /// every subsequent load pay nothing. (The new-tab page is local and never
    /// reaches this gate at all; the launch paint is not blocked on prepare().)
    func testReadyDirectorProceedsSynchronously() {
        let director = director()
        director.markReady()  // as if prepare() already completed
        let spy = SpyContentController()
        var proceeded = false
        director.applyListsThen(to: spy, forHost: "example.com") { proceeded = true }
        XCTAssertTrue(proceeded, "steady state must not defer the navigation")
        XCTAssertEqual(spy.removeAllCount, 1, "reconciled synchronously")
    }
}
