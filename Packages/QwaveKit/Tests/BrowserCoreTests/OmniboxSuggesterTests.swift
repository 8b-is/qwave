import XCTest
import Persistence
@testable import BrowserCore

final class OmniboxSuggesterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func entry(
        _ url: String,
        title: String,
        visits: Int = 1,
        daysAgo: Double = 1
    ) -> HistoryEntry {
        HistoryEntry(
            id: Int64(abs(url.hashValue % 100_000)),
            url: URL(string: url)!,
            title: title,
            visitCount: visits,
            lastVisit: now.addingTimeInterval(-daysAgo * 86_400),
            containerID: nil
        )
    }

    func testEmptyQueryYieldsNothing() {
        let history = [entry("https://example.com", title: "Example")]
        XCTAssertTrue(OmniboxSuggester.suggestions(for: "", history: history, now: now).isEmpty)
        XCTAssertTrue(OmniboxSuggester.suggestions(for: "   ", history: history, now: now).isEmpty)
    }

    func testHostPrefixBeatsTitleMatch() {
        let history = [
            entry("https://github.com/", title: "GitHub"),
            entry("https://example.com/git-tutorial", title: "git tutorial for beginners"),
        ]
        let results = OmniboxSuggester.suggestions(for: "git", history: history, now: now)
        XCTAssertEqual(results.first?.url.absoluteString, "https://github.com/")
        XCTAssertEqual(results.count, 2)
    }

    func testWWWIsIgnoredForPrefixMatching() {
        let history = [entry("https://www.webkit.org/", title: "WebKit")]
        let results = OmniboxSuggester.suggestions(for: "webkit", history: history, now: now)
        XCTAssertEqual(results.count, 1)
    }

    func testFrequentSiteOutranksRareOneAtSameMatchTier() {
        let history = [
            entry("https://news.example/", title: "News", visits: 1),
            entry("https://news.other.example/", title: "Other News", visits: 40),
        ]
        let results = OmniboxSuggester.suggestions(for: "news", history: history, now: now)
        XCTAssertEqual(results.first?.url.absoluteString, "https://news.other.example/")
    }

    func testRecencyBreaksFrequencyTies() {
        let history = [
            entry("https://a.example/", title: "A", visits: 3, daysAgo: 60),
            entry("https://a-recent.example/", title: "A recent", visits: 3, daysAgo: 1),
        ]
        let results = OmniboxSuggester.suggestions(for: "a", history: history, now: now)
        XCTAssertEqual(results.first?.url.absoluteString, "https://a-recent.example/")
    }

    func testDeduplicatesByURL() {
        let history = [
            entry("https://example.com/", title: "Example", visits: 2),
            entry("https://example.com/", title: "Example again", visits: 5),
        ]
        let results = OmniboxSuggester.suggestions(for: "example", history: history, now: now)
        XCTAssertEqual(results.count, 1)
    }

    func testLimitIsRespected() {
        let history = (0..<20).map { entry("https://site\($0).example/", title: "Site \($0)") }
        let results = OmniboxSuggester.suggestions(for: "site", history: history, now: now, limit: 6)
        XCTAssertEqual(results.count, 6)
    }

    func testNoMatchYieldsNothing() {
        let history = [entry("https://example.com/", title: "Example")]
        XCTAssertTrue(OmniboxSuggester.suggestions(for: "zzzz", history: history, now: now).isEmpty)
    }
}
