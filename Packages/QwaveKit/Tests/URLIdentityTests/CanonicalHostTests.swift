import XCTest
import URLIdentity

/// Table-driven proof that host identity is derived the way WebKit derives
/// it — the divergences below are exactly the bypass class from the v0.3.0
/// kickoff (Foundation `URL.host` disagreeing with the WHATWG parser).
final class CanonicalHostTests: XCTestCase {
    func testCanonicalHostTable() {
        let cases: [(input: String, expected: String?)] = [
            // Plain ASCII stays itself, lowercased.
            ("https://example.com/x", "example.com"),
            ("https://EXAMPLE.com", "example.com"),
            ("https://sub.Example.co.uk/a?b=c", "sub.example.co.uk"),
            // IDN → punycode, the identity WebKit actually loads.
            ("https://例え.jp/", "xn--r8jz45g.jp"),
            ("https://измаил.укр/", "xn--80anccpd.xn--j1amh"),
            // Authority confusion: host is the part after the LAST @.
            ("https://user@evil.com@good.example/", "good.example"),
            ("https://user:pass@evil.com@good.example/", "good.example"),
            // Backslashes are slashes in special schemes.
            ("https:\\\\example.com\\path", "example.com"),
            // Non-decimal IPv4 literals normalize to dotted decimal.
            ("https://0x7f.0.0.1/", "127.0.0.1"),
            ("https://0177.0.0.1/", "127.0.0.1"),
            ("https://2130706433/", "127.0.0.1"),
            ("https://192.168.0x10/", "192.168.0.16"),
            // Percent-encoded hosts decode before matching.
            ("https://ex%61mple.com/", "example.com"),
            // ASCII tab/newline are stripped by the WHATWG parser.
            ("https://exa\nmple.com/", "example.com"),
            ("https://exam\tple.com/", "example.com"),
            // IPv6 keeps its bracketed serialization.
            ("https://[::1]/", "[::1]"),
            // No host identity.
            ("about:blank", nil),
            ("file:///tmp/x.html", nil),
            ("not a url", nil),
            ("", nil),
        ]

        for (input, expected) in cases {
            XCTAssertEqual(
                CanonicalHost.host(ofURLString: input), expected,
                "canonical host of \(input.debugDescription)"
            )
        }
    }

    func testFoundationURLPath() {
        let url = URL(string: "https://user@evil.com@good.example/p")
        // Foundation may parse this differently (or not at all) — whatever it
        // does, the canonical identity must be WebKit's.
        if let url {
            XCTAssertEqual(CanonicalHost.host(of: url), "good.example")
        }

        let ascii = URL(string: "https://www.example.com/x")!
        XCTAssertEqual(CanonicalHost.host(of: ascii), "www.example.com")
    }
}
