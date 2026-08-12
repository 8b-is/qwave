import XCTest
import WebKit
@testable import Shields

/// The load-bearing CI check standing in for "runs on a real Mac": the exact
/// JSON we ship must compile through WebKit's real rule-list compiler. A
/// syntax regression in either resource fails the PR instead of failing at
/// runtime on a user's machine.
@MainActor
final class RuleListCompileTests: XCTestCase {
    private func freshStore() throws -> WKContentRuleListStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwave-rulelists-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return WKContentRuleListStore(url: dir)
    }

    func testBundledJSONIsWellFormed() throws {
        for list in RuleListCompiler.BuiltinList.allCases {
            let json = try RuleListCompiler.builtinJSON(for: list)
            let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8))
            let rules = try XCTUnwrap(parsed as? [[String: Any]], "\(list.rawValue) must be an array of rules")
            XCTAssertFalse(rules.isEmpty)
            for rule in rules {
                XCTAssertNotNil(rule["trigger"], "\(list.rawValue): rule missing trigger")
                XCTAssertNotNil(rule["action"], "\(list.rawValue): rule missing action")
            }
        }
    }

    func testShippedBlocklistCompiles() async throws {
        let compiler = RuleListCompiler(store: try freshStore())
        let list = try await compiler.compiledList(for: .adsAndTrackers)
        XCTAssertFalse(list.identifier.isEmpty)
    }

    func testShippedHTTPSUpgradeListCompiles() async throws {
        let compiler = RuleListCompiler(store: try freshStore())
        let list = try await compiler.compiledList(for: .httpsUpgrade)
        XCTAssertFalse(list.identifier.isEmpty)
    }

    func testCompiledListIsCachedInMemory() async throws {
        let compiler = RuleListCompiler(store: try freshStore())
        let first = try await compiler.compiledList(for: .adsAndTrackers)
        let second = try await compiler.compiledList(for: .adsAndTrackers)
        XCTAssertTrue(first === second)
    }

    func testStableHashIsStable() {
        XCTAssertEqual(
            RuleListCompiler.stableHash(of: "qwave"),
            RuleListCompiler.stableHash(of: "qwave")
        )
        XCTAssertNotEqual(
            RuleListCompiler.stableHash(of: "qwave"),
            RuleListCompiler.stableHash(of: "qwave2")
        )
    }
}
