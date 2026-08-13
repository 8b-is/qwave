import XCTest
import SnapshotTesting
@testable import Shields

/// Golden-file tests for the uBO → WebKit content-blocker JSON compiler. Any
/// change to the emitted regexes or trigger shapes surfaces as a reviewable
/// snapshot diff instead of a silent behavioral change.
@MainActor
final class UBORuleCompilerSnapshotTests: XCTestCase {
    /// One representative line per compiler path: anchored host, third-party,
    /// resource types, $domain, anchored path, plain host, substring,
    /// exception, and skipped lines (comment + cosmetic).
    private static let sampleList = """
        ! sample fixture — not a real list
        ||ads.example.com^
        ||tracker.example.com^$third-party
        ||cdn.example.com/banners^$image,script
        ||metrics.example.com^$domain=news.example|~blog.news.example
        beacon.example.net
        /analytics/track.js
        @@||cdn.example.com/banners/allowed.png^
        example.com##.ad-slot
        """

    func testCompiledJSONGolden() throws {
        let (json, skipped, exceptions) = UBORuleListCompiler.compileJSON(from: Self.sampleList)

        XCTAssertEqual(skipped, 2, "comment + cosmetic line")
        XCTAssertEqual(exceptions, 1)

        // JSONSerialization dictionary key order is unspecified; re-serialize
        // with sorted keys so the golden is deterministic across runs.
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let normalized = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        assertSnapshot(of: String(decoding: normalized, as: UTF8.self), as: .lines)
    }
}
