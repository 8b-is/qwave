import XCTest
@testable import BrowserCore

final class OfflineArcadeTests: XCTestCase {
    func testOfflineOnlyAndRetryRoundTrip() throws {
        let original = try XCTUnwrap(URL(string: "https://example.com/a?q=one&b=two#part"))
        for code in [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost] {
            let page = try XCTUnwrap(OfflineArcade.pageURL(error: NSError(domain: NSURLErrorDomain, code: code), failingURL: original))
            XCTAssertEqual(page.host, "arcade")
            XCTAssertEqual(URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, original.absoluteString)
        }
        for code in [NSURLErrorCancelled, NSURLErrorServerCertificateUntrusted, NSURLErrorTimedOut] {
            XCTAssertNil(OfflineArcade.pageURL(error: NSError(domain: NSURLErrorDomain, code: code), failingURL: original))
        }
        XCTAssertNil(OfflineArcade.pageURL(error: NSError(domain: "other", code: NSURLErrorNotConnectedToInternet), failingURL: original))
        XCTAssertNil(OfflineArcade.pageURL(error: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet), failingURL: URL(string: "qwave://arcade")))
    }
    func testBundledPageAndUnsafeRetry() {
        let html = OfflineArcade.html(retry: "javascript:alert(1)")
        XCTAssertTrue(html.contains("Balloon Bounce"))
        XCTAssertTrue(html.contains("href=\"qwave://start\""))
        XCTAssertTrue(html.contains("connect-src 'none'"))
        XCTAssertFalse(html.contains("{{RETRY_URL}}"))
        let escaped = OfflineArcade.html(retry: "https://example.com/?a=1&b=2")
        XCTAssertTrue(escaped.contains("a=1&amp;b=2"))
    }
}

#if canImport(WebKit)
import WebKit

@MainActor
final class OfflineArcadeWebKitTests: XCTestCase {
    func testBundledSchemeRunsGameWithoutRemoteResources() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(QwaveSchemeHandler(), forURLScheme: "qwave")
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        view.load(URLRequest(url: URL(string: "qwave://arcade?retry=https%3A%2F%2Fexample.com%2F")!))
        defer { view.stopLoading() }
        var ready = false
        for _ in 0..<50 {
            ready = (try? await view.evaluateJavaScript("typeof start === 'function' && !!document.querySelector('#start')") as? Bool) == true
            if ready { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(ready, "Bundled arcade must actually execute inside WebKit")
        guard ready else { return }
        let state = try await view.evaluateJavaScript("document.querySelector('#start').click(); document.querySelector('#pause').click(); document.querySelector('#status').textContent") as? String
        XCTAssertEqual(state, "Paused. Take your time.")
        let retry = try await view.evaluateJavaScript("document.querySelector('a').href") as? String
        XCTAssertEqual(retry, "https://example.com/")
        let resources = try await view.evaluateJavaScript("performance.getEntriesByType('resource').length") as? Int
        XCTAssertEqual(resources, 0)
        XCTAssertEqual(view.url?.scheme, "qwave")
    }
}
#endif
