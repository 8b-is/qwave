import Foundation
import WebKit
import XCTest

@testable import BrowserCore
@testable import QwaveSupport
@testable import Shields

/// Drives the actual fetch and observes WebKit's resulting document origin.
/// The transport supplies final response metadata without making any network
/// requests. This tests the consumer of URLSession's redirect result, not the
/// redirect transport itself. All browser/session stores are disposable.
@MainActor
final class MarkdownResponseTests: XCTestCase {
    func testRedirectedRawHTMLUsesFinalOriginAndRelativeLinks() async throws {
        let (tab, web) = try await fetch("redirect")
        let document = try await snapshot(web, containing: "Synthetic response")
        XCTAssertEqual(document["origin"] as? String, "https://response.example")
        XCTAssertEqual(document["base"] as? String, "https://response.example/docs/final.md")
        XCTAssertEqual(document["scriptOrigin"] as? String, "https://response.example")
        XCTAssertEqual(document["link"] as? String, "https://response.example/docs/next.html")
        XCTAssertEqual(tab.url?.absoluteString, "https://response.example/docs/final.md")
        XCTAssertEqual(tab.title, "final.md")
    }

    func testSameOriginMarkdownStillRendersRawHTML() async throws {
        let (tab, web) = try await fetch("same")
        let document = try await snapshot(web, containing: "Synthetic response")
        XCTAssertEqual(document["scriptOrigin"] as? String, "https://request.example")
        XCTAssertEqual(tab.url?.absoluteString, "https://request.example/same.md")
        XCTAssertEqual(tab.title, "same.md")
    }

    func testFinalHTTPOriginIsPreserved() async throws {
        let (tab, web) = try await fetch("http")
        let document = try await snapshot(web, containing: "Synthetic response")
        XCTAssertEqual(document["scriptOrigin"] as? String, "http://response.example")
        XCTAssertEqual(tab.url?.absoluteString, "http://response.example/docs/final.md")
    }

    func testHTTPErrorBodiesAreNotRenderedAsMarkdown() async throws {
        for status in [302, 403, 404, 500] {
            let (tab, web) = try await fetch("status-\(status)")
            let document = try await snapshot(web, containing: String(status))
            XCTAssertEqual(document["scriptOrigin"] as? String, "")
            XCTAssertEqual(document["markdown"] as? Bool, false)
            XCTAssertEqual(document["base"] as? String, "https://response.example/docs/final.md")
            XCTAssertEqual(tab.url?.host, "response.example")
            XCTAssertEqual(tab.title, String(status))
        }
    }

    func testNonWebResponseOriginsAreRejected() async throws {
        for kind in ["file", "internal", "data"] {
            let (_, web) = try await fetch(kind)
            let document = try await snapshot(web, containing: "Lost in the Math")
            XCTAssertEqual(document["scriptOrigin"] as? String, "")
            XCTAssertEqual(document["markdown"] as? Bool, false)
            XCTAssertEqual(document["origin"] as? String, "https://request.example")
        }
    }

    func testNonHTTPResponseIsRejected() async throws {
        let (_, web) = try await fetch("non-http")
        let document = try await snapshot(web, containing: "Lost in the Math")
        XCTAssertEqual(document["scriptOrigin"] as? String, "")
        XCTAssertEqual(document["markdown"] as? Bool, false)
    }

    func testTransportFailureShowsTrustedErrorPage() async throws {
        let (_, web) = try await fetch("failure")
        let document = try await snapshot(web, containing: "Lost in the Math")
        XCTAssertEqual(document["scriptOrigin"] as? String, "")
        XCTAssertEqual(document["markdown"] as? Bool, false)
        XCTAssertEqual(document["base"] as? String, "https://request.example/failure.md")
    }

    private func fetch(_ kind: String) async throws -> (Tab, WKWebView) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "qwave-markdown-response-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.protocolClasses = [EgressGuard.self, MarkdownResponseTransport.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let tab = Tab(isEphemeral: true)
        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.websiteDataStore = .nonPersistent()
        webConfiguration.preferences.isFraudulentWebsiteWarningEnabled = false
        let web = WKWebView(frame: .zero, configuration: webConfiguration)
        tab.attach(webView: web)
        let coordinator = NavigationCoordinator(
            tab: tab,
            shields: ShieldsDirector(
                compiler: RuleListCompiler(store: WKContentRuleListStore(url: directory)!),
                policy: ShieldsPolicy(directory: nil)
            ),
            httpsUpgrader: HTTPSFirstUpgrader(), history: nil,
            downloads: DownloadManager(directory: directory), session: session
        )
        await coordinator.fetchAndPresentMarkdown(URL(string: "https://request.example/\(kind).md")!, in: web)
        return (tab, web)
    }

    private func snapshot(_ web: WKWebView, containing marker: String) async throws -> [String: Any] {
        defer { web.stopLoading() }
        for _ in 0..<100 {
            if let value = try? await web.evaluateJavaScript(
                """
                ({text: document.body?.textContent || '', origin: location.origin,
                  base: document.baseURI, scriptOrigin: window.syntheticScriptOrigin || '',
                  link: document.querySelector('.md-body a')?.href || '',
                  markdown: document.querySelector('.md-body') !== null})
                """
            ) as? [String: Any], (value["text"] as? String)?.contains(marker) == true {
                return value
            }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTFail("Fixture document did not render: \(marker)")
        return [:]
    }
}

private final class MarkdownResponseTransport: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let requested = request.url!
        let kind = requested.deletingPathExtension().lastPathComponent
        if kind == "failure" {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let finalURL: URL
        switch kind {
        case "same": finalURL = requested
        case "http": finalURL = URL(string: "http://response.example/docs/final.md")!
        case "file": finalURL = URL(fileURLWithPath: "/synthetic-qwave-fixture/final.md")
        case "internal": finalURL = URL(string: "qwave://start/final.md")!
        case "data": finalURL = URL(string: "data:text/plain,synthetic")!
        default: finalURL = URL(string: "https://response.example/docs/final.md")!
        }
        let response: URLResponse
        if kind == "non-http" {
            response = URLResponse(
                url: finalURL, mimeType: "text/markdown", expectedContentLength: -1, textEncodingName: "utf-8")
        } else {
            let status = kind.hasPrefix("status-") ? Int(kind.dropFirst(7))! : 200
            response = HTTPURLResponse(
                url: finalURL, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/markdown"])!
        }
        let body = """
            # Synthetic response

            [Next](next.html)

            <script>window.syntheticScriptOrigin = location.origin;</script>
            """
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
