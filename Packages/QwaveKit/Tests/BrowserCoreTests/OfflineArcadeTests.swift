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
