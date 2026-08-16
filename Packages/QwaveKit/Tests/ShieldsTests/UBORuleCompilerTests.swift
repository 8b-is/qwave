import XCTest
import Foundation
@testable import Shields

final class UBOFilterParserTests: XCTestCase {
    func testParsesPlainHost() {
        let filter = UBOFilterParser.parse("example.com")
        guard case .plain(let host, let options) = filter else {
            return XCTFail("expected plain host")
        }
        XCTAssertEqual(host, "example.com")
        XCTAssertTrue(options.isEmpty)
    }

    func testParsesAnchoredHost() {
        let filter = UBOFilterParser.parse("||doubleclick.net^")
        guard case .hostname(let host, _) = filter else {
            return XCTFail("expected anchored host")
        }
        XCTAssertEqual(host, "doubleclick.net")
    }

    func testParsesAnchoredPath() {
        let filter = UBOFilterParser.parse("||example.com/ads/banner.js^")
        guard case .anchoredPath(let host, let path, _) = filter else {
            return XCTFail("expected anchored path")
        }
        XCTAssertEqual(host, "example.com")
        XCTAssertEqual(path, "ads/banner.js")
    }

    func testParsesResourceTypeOptions() {
        let filter = UBOFilterParser.parse("||tracker.example^$script,image")
        guard case .hostname(_, let options) = filter else {
            return XCTFail("expected hostname")
        }
        XCTAssertEqual(options.resourceTypes, ["script", "image"])
    }

    func testParsesThirdParty() {
        let filter = UBOFilterParser.parse("||ads.example^$third-party")
        guard case .hostname(_, let options) = filter else {
            return XCTFail("expected hostname")
        }
        XCTAssertEqual(options.loadType, "third-party")
    }

    func testParsesDomainOption() {
        let filter = UBOFilterParser.parse("||ads.example^$domain=example.com|~trusted.example")
        guard case .hostname(_, let options) = filter else {
            return XCTFail("expected hostname")
        }
        XCTAssertEqual(options.domains, ["example.com"])
        XCTAssertEqual(options.notDomains, ["trusted.example"])
    }

    func testParsesException() {
        let filter = UBOFilterParser.parse("@@||example.com/analytics^")
        guard case .exception(let pattern, _) = filter else {
            return XCTFail("expected exception")
        }
        XCTAssertEqual(pattern, "||example.com/analytics")
    }

    func testIgnoresCommentsAndCosmetics() {
        XCTAssertEqual(UBOFilterParser.parse("! comment"), .ignore)
        XCTAssertEqual(UBOFilterParser.parse("[Adblock Plus 2.0]"), .ignore)
        XCTAssertEqual(UBOFilterParser.parse("example.com##.ad-banner"), .ignore)
        XCTAssertEqual(UBOFilterParser.parse("example.com#@#.ad-banner"), .ignore)
        XCTAssertEqual(UBOFilterParser.parse(""), .ignore)
    }
}

final class UBORuleListCompilerTests: XCTestCase {
    func testCompilesBlockingAndExceptions() throws {
        let text = """
            [Adblock Plus 2.0]
            ! comment
            ||doubleclick.net^
            example.com
            @@||example.com/analytics^$script
            """
        let (json, skipped, exceptions) = UBORuleListCompiler.compileJSON(from: text)
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        // Four, not three: the bare `example.com` line is a `.plain` filter and
        // compiles to a pair of rules, because its boundary was an alternation
        // WebKit will not compile (#134). `exceptions` still counts filters.
        XCTAssertEqual(rules.count, 4)
        XCTAssertEqual(exceptions, 1)
        XCTAssertEqual(skipped, 2)

        // Exceptions must sort after blocking rules.
        let actions = rules.compactMap { ($0["action"] as? [String: Any])?["type"] as? String }
        XCTAssertEqual(actions, ["block", "block", "block", "ignore-previous-rules"])

        let last = try XCTUnwrap(rules.last)
        let trigger = try XCTUnwrap(last["trigger"] as? [String: Any])
        let resourceTypes = try XCTUnwrap(trigger["resource-type"] as? [String])
        XCTAssertEqual(resourceTypes, ["script"])
    }

    /// WebKit's url-filter is a substring (search) match, like
    /// NSRegularExpression.firstMatch.
    private func matches(_ regex: String, _ string: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: regex) else { return false }
        let range = expression.firstMatch(
            in: string,
            range: NSRange(location: 0, length: (string as NSString).length)
        )?.range
        return range != nil
    }

    func testAnchoredHostRegex() {
        let regex = UBORuleListCompiler.anchoredHostRegex(host: "doubleclick.net")
        XCTAssertTrue(matches(regex, "https://ad.doubleclick.net/foo"))
        // Canonical form: WebKit matches `http://doubleclick.net/`, never the
        // slash-less spelling, which is why the boundary alternation the engine
        // rejected could be dropped rather than replaced (#134).
        XCTAssertTrue(matches(regex, "http://doubleclick.net/"))
        XCTAssertFalse(matches(regex, "http://doubleclick.net"))
        XCTAssertTrue(matches(regex, "https://doubleclick.net:443/x"))
        XCTAssertFalse(matches(regex, "https://doubleclick.net.evil.com/foo"))
        XCTAssertFalse(matches(regex, "https://evildoubleclick.net/foo"))
    }

    func testPlainHostRegex() {
        let regex = UBORuleListCompiler.plainHostRegex(host: "example.com")
        XCTAssertTrue(matches(regex, "https://www.example.com/path"))
        XCTAssertFalse(matches(regex, "https://example.com.evil.net/path"))
        // The host ending the URL is the second rule's job — the two together
        // are the alternation WebKit would not take (#134).
        let atEnd = UBORuleListCompiler.plainHostRegexAtEndOfURL(host: "example.com")
        XCTAssertFalse(matches(regex, "https://other.test/?u=example.com"))
        XCTAssertTrue(matches(atEnd, "https://other.test/?u=example.com"))
        XCTAssertFalse(matches(atEnd, "https://other.test/?u=example.common"))
    }

    func testChunkedCompilation() {
        var lines = ["||blocked.example^"]
        for i in 0..<10 {
            lines.append("||tracker\(i).example^")
        }
        let chunks = UBORuleListCompiler.compileJSONChunked(from: lines.joined(separator: "\n"))
        XCTAssertEqual(chunks.count, 1)
        let rules = try! JSONSerialization.jsonObject(with: Data(chunks[0].utf8)) as! [[String: Any]]
        XCTAssertEqual(rules.count, 11)
    }

    func testBlocklistCompilationResultSurvivesDetachedWork() async throws {
        let result = await Task.detached {
            UBORuleListCompiler.compileJSON(from: "||ads.example^\n@@||ads.example/allowed^")
        }.value

        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.0.utf8)) as? [[String: Any]])
        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual(result.1, 0)
        XCTAssertEqual(result.2, 1)
    }
}

// MARK: - Updater with ETag caching

private actor MockETagStore: ETagStoring {
    var storage: [String: String] = [:]
    func etag(for key: String) -> String? { storage[key] }
    func setETag(_ etag: String?, for key: String) { storage[key] = etag }
}

private struct StubResponse: Sendable {
    let status: Int
    let body: String
    let etag: String?
}

private final class StubState: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (URLRequest) -> StubResponse)?
    private var lastRequest: URLRequest?

    func setHandler(_ handler: @escaping @Sendable (URLRequest) -> StubResponse) {
        lock.withLock {
            self.handler = handler
            lastRequest = nil
        }
    }

    func handler(for request: URLRequest) -> (@Sendable (URLRequest) -> StubResponse)? {
        lock.withLock {
            lastRequest = request
            return handler
        }
    }

    func recordedRequest() -> URLRequest? {
        lock.withLock { lastRequest }
    }
}

private final class StubURLProtocol: URLProtocol {
    private static let state = StubState()

    static func setHandler(_ handler: @escaping @Sendable (URLRequest) -> StubResponse) {
        state.setHandler(handler)
    }

    static var lastRequest: URLRequest? {
        state.recordedRequest()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let handler = Self.state.handler(for: request)
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let result = handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: result.status,
            httpVersion: nil,
            headerFields: result.etag.map { ["ETag": $0] }
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(result.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class RemoteBlocklistUpdaterTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: config)
    }

    func testFirstFetchCompilesAndStoresETag() async throws {
        let etags = MockETagStore()
        StubURLProtocol.setHandler { _ in
            StubResponse(status: 200, body: "||ads.example^\n@@||ads.example/ok^", etag: "W/\"abc123\"")
        }
        let updater = RemoteBlocklistUpdater(
            sourceURL: URL(string: "https://example.test/list.txt")!,
            session: session,
            etags: etags
        )
        let json = try await updater.fetchUpdatedBlocklistJSON()
        XCTAssertNotNil(json)
        let storedETag = await etags.etag(for: "https://example.test/list.txt")
        XCTAssertEqual(storedETag, "W/\"abc123\"")

        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json!.utf8)) as? [[String: Any]])
        XCTAssertEqual(rules.count, 2)
    }

    func test304ReturnsNilWithoutStoring() async throws {
        let etags = MockETagStore()
        await etags.setETag("W/\"abc123\"", for: "https://example.test/list.txt")
        StubURLProtocol.setHandler { _ in
            StubResponse(status: 304, body: "", etag: nil)
        }
        let updater = RemoteBlocklistUpdater(
            sourceURL: URL(string: "https://example.test/list.txt")!,
            session: session,
            etags: etags
        )
        let json = try await updater.fetchUpdatedBlocklistJSON()
        XCTAssertNil(json)
        XCTAssertEqual(
            StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "If-None-Match"),
            "W/\"abc123\""
        )
        let storedETag = await etags.etag(for: "https://example.test/list.txt")
        XCTAssertEqual(storedETag, "W/\"abc123\"")
    }

    func testChangedContentReplacesETag() async throws {
        let etags = MockETagStore()
        await etags.setETag("W/\"old\"", for: "https://example.test/list.txt")
        StubURLProtocol.setHandler { _ in
            StubResponse(status: 200, body: "||new.example^", etag: "W/\"new\"")
        }
        let updater = RemoteBlocklistUpdater(
            sourceURL: URL(string: "https://example.test/list.txt")!,
            session: session,
            etags: etags
        )
        let json = try await updater.fetchUpdatedBlocklistJSON()
        XCTAssertNotNil(json)
        let storedETag = await etags.etag(for: "https://example.test/list.txt")
        XCTAssertEqual(storedETag, "W/\"new\"")
    }
}
