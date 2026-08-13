import XCTest
import URLIdentity
@testable import BrowserCore

final class OmniboxParserTests: XCTestCase {
    private func assertURL(_ input: String, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .url(let url) = OmniboxParser.parse(input) else {
            return XCTFail("expected URL for \(input)", file: file, line: line)
        }
        XCTAssertEqual(url.absoluteString, expected, file: file, line: line)
    }

    private func assertSearch(_ input: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .search = OmniboxParser.parse(input) else {
            return XCTFail("expected search for \(input)", file: file, line: line)
        }
    }

    func testExplicitSchemes() {
        assertURL("https://example.com", "https://example.com")
        assertURL("http://example.com/a?b=c", "http://example.com/a?b=c")
        assertURL("about:blank", "about:blank")
        assertURL("file:///tmp/x.html", "file:///tmp/x.html")
        assertURL("qwave://start", "qwave://start")
    }

    func testExistingUnixPathBecomesFileURL() {
        guard case .url(let url) = OmniboxParser.parse("/tmp") else {
            return XCTFail("expected file URL for /tmp")
        }
        XCTAssertTrue(url.isFileURL)
        XCTAssertTrue(url.path.hasSuffix("tmp"))
    }

    func testBareDomains() {
        assertURL("example.com", "https://example.com")
        assertURL("Example.COM", "https://Example.COM")
        assertURL("sub.example.co.uk", "https://sub.example.co.uk")
        assertURL("example.com/path?q=1", "https://example.com/path?q=1")
        assertURL("webkit.org", "https://webkit.org")
    }

    func testLocalhostAndIPs() {
        assertURL("localhost", "https://localhost")
        assertURL("localhost:8080", "https://localhost:8080")
        assertURL("localhost:8080/admin", "https://localhost:8080/admin")
        assertURL("192.168.1.1", "https://192.168.1.1")
        assertURL("10.0.0.2:3000", "https://10.0.0.2:3000")
    }

    func testHostWithPort() {
        assertURL("example.com:8443", "https://example.com:8443")
    }

    func testSearches() {
        assertSearch("how do wave functions collapse")
        assertSearch("swift")
        assertSearch("what is 2.5 + 2.5")
        assertSearch("example .com")
        assertSearch("weather 90210")
        assertSearch("1.2.3.4.5 meaning")
        assertSearch("note:buy milk")
        assertSearch("c++ lambda syntax")
        assertSearch("")
        assertSearch("   ")
    }

    func testDotButNotDomain() {
        assertSearch("v1.2")  // numeric TLD-alike
        assertSearch("filename.")  // empty label
        assertSearch(".hidden")  // empty label
    }

    func testWhitespaceTrimming() {
        assertURL("  example.com  ", "https://example.com")
    }

    // MARK: - WHATWG canonical identity (host-identity bypass class)

    private func hostOf(_ input: String, file: StaticString = #filePath, line: UInt = #line) -> String? {
        guard case .url(let url) = OmniboxParser.parse(input) else {
            XCTFail("expected URL for \(input)", file: file, line: line)
            return nil
        }
        // The identity WebKit will load — asserted via the same canonical
        // derivation the shields policy uses.
        return CanonicalHost.host(of: url)
    }

    func testIDNInputYieldsPunycodeIdentity() {
        XCTAssertEqual(hostOf("例え.jp"), "xn--r8jz45g.jp")
        XCTAssertEqual(hostOf("https://例え.jp/path"), "xn--r8jz45g.jp")
    }

    func testAuthorityConfusionResolvesToWebKitHost() {
        // Foundation and WebKit historically disagree here; whatever URL the
        // parser returns must carry WebKit's identity: the part after the
        // last "@".
        XCTAssertEqual(hostOf("https://user@evil.com@good.example/"), "good.example")
    }

    func testPercentEncodedHostCanonicalizes() {
        XCTAssertEqual(hostOf("https://ex%61mple.com/"), "example.com")
    }

    func testNonDecimalIPv4Canonicalizes() {
        XCTAssertEqual(hostOf("https://0x7f.0.0.1/"), "127.0.0.1")
    }

    func testCanonicalAndFoundationAgreeOnPlainASCII() {
        // The guard must not disturb the common case: identical output to
        // the pre-WebURL parser (no trailing slash added, case preserved).
        assertURL("example.com", "https://example.com")
        assertURL("Example.COM", "https://Example.COM")
    }
}
