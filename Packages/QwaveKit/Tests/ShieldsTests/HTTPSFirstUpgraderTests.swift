import XCTest
@testable import Shields

@MainActor
final class HTTPSFirstUpgraderTests: XCTestCase {
    func testUpgradesPlainHTTPMainFrame() {
        let upgrader = HTTPSFirstUpgrader()
        let decision = upgrader.decision(
            for: URL(string: "http://example.com/page?q=1")!,
            isMainFrame: true,
            policyAllowsUpgrade: true
        )
        XCTAssertEqual(decision, .upgrade(URL(string: "https://example.com/page?q=1")!))
    }

    func testLeavesHTTPSAlone() {
        let upgrader = HTTPSFirstUpgrader()
        XCTAssertEqual(
            upgrader.decision(for: URL(string: "https://example.com/")!, isMainFrame: true, policyAllowsUpgrade: true),
            .allow
        )
    }

    func testLeavesSubframesAlone() {
        let upgrader = HTTPSFirstUpgrader()
        XCTAssertEqual(
            upgrader.decision(for: URL(string: "http://example.com/")!, isMainFrame: false, policyAllowsUpgrade: true),
            .allow
        )
    }

    func testRespectsPolicyOptOut() {
        let upgrader = HTTPSFirstUpgrader()
        XCTAssertEqual(
            upgrader.decision(for: URL(string: "http://example.com/")!, isMainFrame: true, policyAllowsUpgrade: false),
            .allow
        )
    }

    func testSkipsLocalHosts() {
        let upgrader = HTTPSFirstUpgrader()
        for raw in ["http://localhost/", "http://localhost:8080/x", "http://127.0.0.1/", "http://myserver/", "http://printer.local/", "http://192.168.1.10/admin"] {
            XCTAssertEqual(
                upgrader.decision(for: URL(string: raw)!, isMainFrame: true, policyAllowsUpgrade: true),
                .allow,
                "should not upgrade \(raw)"
            )
        }
    }

    func testSkipsExplicitNonDefaultPort() {
        let upgrader = HTTPSFirstUpgrader()
        XCTAssertEqual(
            upgrader.decision(for: URL(string: "http://example.com:8080/")!, isMainFrame: true, policyAllowsUpgrade: true),
            .allow
        )
    }

    func testUpgradesExplicitPort80AndDropsIt() {
        let upgrader = HTTPSFirstUpgrader()
        XCTAssertEqual(
            upgrader.decision(for: URL(string: "http://example.com:80/a")!, isMainFrame: true, policyAllowsUpgrade: true),
            .upgrade(URL(string: "https://example.com/a")!)
        )
    }

    func testFallbackAfterTLSFailureThenAllowsHTTPForSession() {
        let upgrader = HTTPSFirstUpgrader()
        let httpURL = URL(string: "http://broken.example.com/")!
        guard case .upgrade(let httpsURL) = upgrader.decision(for: httpURL, isMainFrame: true, policyAllowsUpgrade: true) else {
            return XCTFail("expected upgrade")
        }

        let fallback = upgrader.fallbackURL(afterFailureOf: httpsURL, errorCode: NSURLErrorSecureConnectionFailed)
        XCTAssertEqual(fallback, httpURL)
        XCTAssertTrue(upgrader.isSessionFallbackHost("broken.example.com"))

        // Second visit this session: no more upgrade attempts.
        XCTAssertEqual(
            upgrader.decision(for: httpURL, isMainFrame: true, policyAllowsUpgrade: true),
            .allow
        )
    }

    func testNoFallbackForUnrelatedError() {
        let upgrader = HTTPSFirstUpgrader()
        let httpURL = URL(string: "http://ok.example.com/")!
        guard case .upgrade(let httpsURL) = upgrader.decision(for: httpURL, isMainFrame: true, policyAllowsUpgrade: true) else {
            return XCTFail("expected upgrade")
        }
        XCTAssertNil(upgrader.fallbackURL(afterFailureOf: httpsURL, errorCode: NSURLErrorCancelled))
    }

    func testNoFallbackForHostWeNeverUpgraded() {
        let upgrader = HTTPSFirstUpgrader()
        XCTAssertNil(
            upgrader.fallbackURL(
                afterFailureOf: URL(string: "https://stranger.example.com/")!,
                errorCode: NSURLErrorSecureConnectionFailed
            )
        )
    }
}
