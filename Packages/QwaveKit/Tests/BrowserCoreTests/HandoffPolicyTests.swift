import XCTest

@testable import BrowserCore

final class HandoffPolicyTests: XCTestCase {
    private func url(_ s: String) -> URL { URL(string: s)! }

    func testHttpAndHttpsPagesAreHandedOff() {
        XCTAssertEqual(
            HandoffPolicy.webpageURL(url: url("http://example.com/a"), isPrivateWindow: false, isEphemeralTab: false),
            url("http://example.com/a"))
        XCTAssertEqual(
            HandoffPolicy.webpageURL(url: url("https://example.com/b"), isPrivateWindow: false, isEphemeralTab: false),
            url("https://example.com/b"))
    }

    func testPrivateWindowIsNeverHandedOff() {
        XCTAssertNil(
            HandoffPolicy.webpageURL(url: url("https://example.com"), isPrivateWindow: true, isEphemeralTab: false))
    }

    func testEphemeralTabIsNeverHandedOff() {
        XCTAssertNil(
            HandoffPolicy.webpageURL(url: url("https://example.com"), isPrivateWindow: false, isEphemeralTab: true))
    }

    func testNonWebSchemesAreSuppressed() {
        // Internal start page, file documents, and anything non-http(s).
        XCTAssertNil(
            HandoffPolicy.webpageURL(url: url("qwave://start"), isPrivateWindow: false, isEphemeralTab: false))
        XCTAssertNil(
            HandoffPolicy.webpageURL(url: url("file:///Users/x/doc.pdf"), isPrivateWindow: false, isEphemeralTab: false)
        )
        XCTAssertNil(
            HandoffPolicy.webpageURL(url: url("about:blank"), isPrivateWindow: false, isEphemeralTab: false))
    }

    func testNilURLIsSuppressed() {
        XCTAssertNil(HandoffPolicy.webpageURL(url: nil, isPrivateWindow: false, isEphemeralTab: false))
    }

    func testSchemeMatchingIsCaseInsensitive() {
        XCTAssertEqual(
            HandoffPolicy.webpageURL(url: url("HTTPS://Example.com/C"), isPrivateWindow: false, isEphemeralTab: false),
            url("HTTPS://Example.com/C"))
    }
}
