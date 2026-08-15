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

    // MARK: - On-device fusion (bookmarks / open tabs / actions)

    private func bookmark(_ url: String, title: String) -> Bookmark {
        Bookmark(id: Int64(abs(url.hashValue % 100_000)), title: title, url: URL(string: url)!, folder: nil, created: now)
    }

    func testOnDeviceIncludesBookmarks() {
        let results = OmniboxSuggester.onDeviceSuggestions(
            for: "rust",
            history: [],
            bookmarks: [bookmark("https://rust-lang.org/", title: "Rust")],
            now: now
        )
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.kind, .bookmark)
        XCTAssertEqual(results.first?.url.absoluteString, "https://rust-lang.org/")
    }

    func testOnDeviceIncludesOpenTabs() {
        let id = UUID()
        let results = OmniboxSuggester.onDeviceSuggestions(
            for: "swift",
            history: [],
            openTabs: [OpenTabInfo(id: id, title: "Swift.org", url: URL(string: "https://swift.org/")!)],
            now: now
        )
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.kind, .openTab(id: id))
    }

    func testOpenTabOutranksAndDedupesHistoryForSameURL() {
        let id = UUID()
        let url = "https://example.com/"
        let results = OmniboxSuggester.onDeviceSuggestions(
            for: "example",
            history: [entry(url, title: "Example", visits: 50)],
            openTabs: [OpenTabInfo(id: id, title: "Example", url: URL(string: url)!)],
            now: now
        )
        // Same URL collapses to a single row, and the open tab wins.
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.kind, .openTab(id: id))
    }

    func testActionMatchesByKeyword() {
        let results = OmniboxSuggester.onDeviceSuggestions(
            for: "timeline",
            history: [],
            actions: OmniboxAction.defaults,
            now: now
        )
        XCTAssertEqual(results.first?.kind, .action)
        XCTAssertEqual(results.first?.url, InternalPages.timelineURL)
    }

    func testOnDeviceNeverEmitsNetworkSearchRows() {
        let results = OmniboxSuggester.onDeviceSuggestions(
            for: "e",
            history: [entry("https://example.com/", title: "Example")],
            bookmarks: [bookmark("https://elm-lang.org/", title: "Elm")],
            actions: OmniboxAction.defaults,
            now: now
        )
        for result in results {
            if case .search = result.kind { XCTFail("on-device path must not produce network rows") }
        }
    }

    func testHybridWithoutRemoteStaysOnDevice() {
        let hybrid = OmniboxSuggester.hybridSuggestions(
            for: "example",
            history: [entry("https://example.com/", title: "Example")],
            remoteSuggestions: [],
            now: now
        )
        XCTAssertEqual(hybrid.count, 1)
        XCTAssertEqual(hybrid.first?.kind, .history)
    }
}
