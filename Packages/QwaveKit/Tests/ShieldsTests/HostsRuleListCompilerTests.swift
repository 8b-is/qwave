import Foundation
import WebKit
import XCTest

@testable import Shields

/// Unit coverage for the zero-egress Safe Browsing compiler and proof that the
/// bundled compiled resource is the faithful, up-to-date compilation of the
/// bundled hosts source — so editing the .txt without recompiling is caught.
@MainActor
final class HostsRuleListCompilerTests: XCTestCase {

    func testParsesHostsFileAndBareHostsSortedAndDeduped() {
        let text = """
            # comment line
            0.0.0.0 evil.example
            127.0.0.1 phish.test   # inline comment stripped
            bare-host.invalid
            0.0.0.0 evil.example
            0.0.0.0 localhost
            0.0.0.0 nodot

            """
        XCTAssertEqual(
            HostsRuleListCompiler.hosts(from: text),
            ["bare-host.invalid", "evil.example", "phish.test"]
        )
    }

    func testCompileJSONEmitsOneBlockRulePerHost() throws {
        let json = HostsRuleListCompiler.compileJSON(from: "0.0.0.0 evil.example\nbad.test")
        let rules = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        XCTAssertEqual(rules.count, 2)
        for rule in rules {
            let action = try XCTUnwrap(rule["action"] as? [String: String])
            XCTAssertEqual(action["type"], "block")
            let trigger = try XCTUnwrap(rule["trigger"] as? [String: Any])
            XCTAssertNotNil(trigger["url-filter"])
        }
    }

    func testEmptyOrCommentOnlyInputYieldsEmptyRuleSet() {
        XCTAssertEqual(HostsRuleListCompiler.compileJSON(from: "# only comments\n\n"), "[]")
    }

    /// The load-bearing sync check: the committed malicious-hosts-compiled.json
    /// must equal the compiler's output for the committed malicious-hosts.txt.
    func testBundledCompiledResourceMatchesSource() throws {
        let sourceText = try HostsRuleListCompiler.bundledSource()
        let expected = HostsRuleListCompiler.compileJSON(from: sourceText)

        let bundled = try RuleListCompiler.builtinJSON(for: .safeBrowsing)

        // Compare as parsed JSON so a trailing newline in the resource file is
        // not treated as a mismatch.
        let expectedRules = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(expected.utf8)) as? NSArray)
        let bundledRules = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(bundled.utf8)) as? NSArray)
        XCTAssertEqual(
            bundledRules, expectedRules,
            "malicious-hosts-compiled.json is stale — regenerate it from malicious-hosts.txt")
    }

    /// The compiled Safe Browsing list must pass through WebKit's real
    /// rule-list compiler, exactly as CI stands in for a real Mac.
    func testSafeBrowsingListCompilesThroughWebKit() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwave-safebrowsing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let compiler = RuleListCompiler(store: WKContentRuleListStore(url: dir)!)
        let list = try await compiler.compiledList(for: .safeBrowsing)
        XCTAssertFalse(list.identifier.isEmpty)
    }
}
