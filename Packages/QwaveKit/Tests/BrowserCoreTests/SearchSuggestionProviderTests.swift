import XCTest
import Persistence
@testable import BrowserCore

final class SearchSuggestionProviderTests: XCTestCase {
    func testParseOpenSearchJSON() {
        let json = """
            ["swift lang", ["swift language", "swift language tutorial", "swift language guide"]]
            """
        let data = Data(json.utf8)
        let suggestions = SearchSuggestionParser.parseJSON(data, provider: "DuckDuckGo")
        XCTAssertEqual(suggestions.count, 3)
        XCTAssertEqual(suggestions[0].text, "swift language")
        XCTAssertEqual(suggestions[1].text, "swift language tutorial")
        XCTAssertEqual(suggestions[2].text, "swift language guide")
        XCTAssertEqual(suggestions[0].provider, "DuckDuckGo")
    }

    func testParseDuckDuckGoDictionaryArrayJSON() {
        let json = """
            [
              {"phrase": "apple silicon"},
              {"phrase": "apple developer"}
            ]
            """
        let data = Data(json.utf8)
        let suggestions = SearchSuggestionParser.parseJSON(data, provider: "DuckDuckGo")
        XCTAssertEqual(suggestions.count, 2)
        XCTAssertEqual(suggestions[0].text, "apple silicon")
        XCTAssertEqual(suggestions[1].text, "apple developer")
    }

    func testHybridSuggestionsCombinesHistoryAndRemote() {
        let history = [
            HistoryEntry(
                id: 1,
                url: URL(string: "https://github.com/swift")!,
                title: "Swift on GitHub",
                visitCount: 10,
                lastVisit: Date(),
                containerID: nil
            )
        ]

        let remote = [
            RemoteSearchSuggestion(text: "swift on github", provider: "DuckDuckGo"),  // duplicate should be filtered
            RemoteSearchSuggestion(text: "swift documentation", provider: "DuckDuckGo"),
            RemoteSearchSuggestion(text: "swift concurrency", provider: "DuckDuckGo"),
        ]

        let hybrid = OmniboxSuggester.hybridSuggestions(
            for: "swift",
            history: history,
            remoteSuggestions: remote,
            limit: 4
        )

        XCTAssertEqual(hybrid.count, 3)
        XCTAssertEqual(hybrid[0].kind, .history)
        XCTAssertEqual(hybrid[0].url.absoluteString, "https://github.com/swift")

        if case .search(let provider) = hybrid[1].kind {
            XCTAssertEqual(provider, "DuckDuckGo")
            XCTAssertEqual(hybrid[1].title, "swift documentation")
        } else {
            XCTFail("Expected search suggestion kind")
        }

        if case .search(let provider) = hybrid[2].kind {
            XCTAssertEqual(provider, "DuckDuckGo")
            XCTAssertEqual(hybrid[2].title, "swift concurrency")
        } else {
            XCTFail("Expected search suggestion kind")
        }
    }
}
