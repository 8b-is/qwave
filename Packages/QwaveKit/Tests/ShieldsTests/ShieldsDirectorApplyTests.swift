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
}
