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

    // MARK: - Ecosia end to end

    /// The Ecosia provider parses the OpenSearch shape `ac.ecosia.org`
    /// answers with, and labels the suggestions honestly.
    func testEcosiaProviderParsesOpenSearchResponse() async throws {
        let json = """
            ["swift", ["swift language", "swift tutorial", "swift on github"]]
            """
        let provider = EcosiaSuggestionProvider(
            session: URLSession(configuration: StubResponse.configuration(body: json)))
        let suggestions = try await provider.fetchSuggestions(for: "swift")
        XCTAssertEqual(suggestions.map(\.text), ["swift language", "swift tutorial", "swift on github"])
        XCTAssertTrue(suggestions.allSatisfy { $0.provider == "Ecosia" })
    }

    /// The request the Ecosia provider builds must hit the autocomplete
    /// subdomain with the OpenSearch query parameters.
    func testEcosiaProviderBuildsTheAutocompleteURL() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLCaptureProtocol.self]
        let provider = EcosiaSuggestionProvider(session: URLSession(configuration: config))

        _ = try await provider.fetchSuggestions(for: "plant trees")

        let captured = try XCTUnwrap(URLCaptureProtocol.captured)
        XCTAssertEqual(captured.host, "ac.ecosia.org")
        XCTAssertEqual(captured.path, "/autocomplete")
        let components = try XCTUnwrap(URLComponents(url: captured, resolvingAgainstBaseURL: false))
        let queryItems = components.queryItems ?? []
        XCTAssertTrue(queryItems.contains(URLQueryItem(name: "q", value: "plant trees")))
        XCTAssertTrue(queryItems.contains(URLQueryItem(name: "type", value: "list")))
    }

    /// Only engines with a vetted keyless endpoint get a provider; the rest
    /// get nil, and no engine is silently mapped onto another engine's
    /// endpoint.
    func testFactoryMapsEnginesToProviders() {
        XCTAssertTrue(SearchSuggestionProviderFactory.provider(for: .ecosia) is EcosiaSuggestionProvider)
        XCTAssertTrue(SearchSuggestionProviderFactory.provider(for: .duckduckgo) is DuckDuckGoSuggestionProvider)
        for engine in [SearchEngine.brave, .startpage, .google, .kagi] {
            XCTAssertNil(SearchSuggestionProviderFactory.provider(for: engine), "\(engine) has no vetted endpoint")
        }
    }

    /// The Category-A host check key follows the same mapping.
    func testFactoryMapsEnginesToEgressHosts() {
        XCTAssertEqual(SearchSuggestionProviderFactory.egressHost(for: .ecosia), "ac.ecosia.org")
        XCTAssertEqual(SearchSuggestionProviderFactory.egressHost(for: .duckduckgo), "duckduckgo.com")
        for engine in [SearchEngine.brave, .startpage, .google, .kagi] {
            XCTAssertNil(SearchSuggestionProviderFactory.egressHost(for: engine))
        }
    }

    /// The default suggestion commit URL is the default engine: Ecosia.
    func testHybridSuggestionsDefaultCommitURLIsEcosia() {
        let hybrid = OmniboxSuggester.hybridSuggestions(
            for: "swift",
            history: [],
            remoteSuggestions: [RemoteSearchSuggestion(text: "swift language", provider: "Ecosia")]
        )
        XCTAssertEqual(hybrid.count, 1)
        XCTAssertEqual(
            hybrid[0].url.absoluteString,
            "https://www.ecosia.org/search?q=swift%20language"
        )
    }
}

/// Captures the request URL a provider built, then answers the OpenSearch
/// empty-list shape so the provider completes normally.
final class URLCaptureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var captured: URL?
    private static let lock = NSLock()

    static func reset() {
        lock.withLock { captured = nil }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        URLCaptureProtocol.lock.withLock { URLCaptureProtocol.captured = request.url }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("[]".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A stub transport that answers a canned JSON body with HTTP 200.
enum StubResponse {
    static func configuration(body: String) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BodyProtocol.self]
        BodyProtocol.body = body
        return config
    }

    final class BodyProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var body = ""
        private static let lock = NSLock()

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(BodyProtocol.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }
}
