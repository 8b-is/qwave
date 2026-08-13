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
        XCTAssertEqual(rules.count, 3)
        XCTAssertEqual(exceptions, 1)
        XCTAssertEqual(skipped, 2)

        // Exceptions must sort after blocking rules.
        let actions = rules.compactMap { ($0["action"] as? [String: Any])?["type"] as? String }
        XCTAssertEqual(actions, ["block", "block", "ignore-previous-rules"])

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
        XCTAssertTrue(matches(regex, "http://doubleclick.net"))
        XCTAssertTrue(matches(regex, "https://doubleclick.net:443/x"))
        XCTAssertFalse(matches(regex, "https://doubleclick.net.evil.com/foo"))
        XCTAssertFalse(matches(regex, "https://evildoubleclick.net/foo"))
    }

    func testPlainHostRegex() {
        let regex = UBORuleListCompiler.plainHostRegex(host: "example.com")
        XCTAssertTrue(matches(regex, "https://www.example.com/path"))
        XCTAssertTrue(matches(regex, "https://example.com"))
        XCTAssertFalse(matches(regex, "https://example.com.evil.net/path"))
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
}

// MARK: - Updater with ETag caching

private final class MockETagStore: ETagStoring, @unchecked Sendable {
    var storage: [String: String] = [:]
    func etag(for key: String) -> String? { storage[key] }
    func setETag(_ etag: String?, for key: String) { storage[key] = etag }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) -> (status: Int, body: String, etag: String?))?
    static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        StubURLProtocol.lastRequest = request
        guard let handler = StubURLProtocol.handler else {
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
        StubURLProtocol.handler = { _ in
            (200, "||ads.example^\n@@||ads.example/ok^", "W/\"abc123\"")
        }
        let updater = RemoteBlocklistUpdater(
            sourceURL: URL(string: "https://example.test/list.txt")!,
            session: session,
            etags: etags
        )
        let json = try await updater.fetchUpdatedBlocklistJSON()
        XCTAssertNotNil(json)
        XCTAssertEqual(etags.etag(for: "https://example.test/list.txt"), "W/\"abc123\"")

        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json!.utf8)) as? [[String: Any]])
        XCTAssertEqual(rules.count, 2)
    }

    func test304ReturnsNilWithoutStoring() async throws {
        let etags = MockETagStore()
        etags.setETag("W/\"abc123\"", for: "https://example.test/list.txt")
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "W/\"abc123\"")
            return (304, "", nil)
        }
        let updater = RemoteBlocklistUpdater(
            sourceURL: URL(string: "https://example.test/list.txt")!,
            session: session,
            etags: etags
        )
        let json = try await updater.fetchUpdatedBlocklistJSON()
        XCTAssertNil(json)
        XCTAssertEqual(etags.etag(for: "https://example.test/list.txt"), "W/\"abc123\"")
    }

    func testChangedContentReplacesETag() async throws {
        let etags = MockETagStore()
        etags.setETag("W/\"old\"", for: "https://example.test/list.txt")
        StubURLProtocol.handler = { _ in
            (200, "||new.example^", "W/\"new\"")
        }
        let updater = RemoteBlocklistUpdater(
            sourceURL: URL(string: "https://example.test/list.txt")!,
            session: session,
            etags: etags
        )
        let json = try await updater.fetchUpdatedBlocklistJSON()
        XCTAssertNotNil(json)
        XCTAssertEqual(etags.etag(for: "https://example.test/list.txt"), "W/\"new\"")
    }
}
