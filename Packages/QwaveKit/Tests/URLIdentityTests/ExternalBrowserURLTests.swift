import Foundation
import XCTest
@testable import URLIdentity

final class ExternalBrowserURLTests: XCTestCase {
    func testOrdinaryWebLinks() throws {
        for raw in ["https://github.com/login?return_to=%2F#passkey", "http://localhost:8080/test", "HTTPS://example.com/path"] {
            XCTAssertTrue(ExternalBrowserURL.isAllowed(try XCTUnwrap(URL(string: raw))))
        }
    }

    func testRejectsExternalCommandsAndUserInfo() throws {
        for raw in ["javascript:alert(1)", "file:///tmp/secret", "data:text/html,hello", "qwave://diagnostics", "about:blank", "https:///", "https://user:password@example.com/", "https://user@example.com/"] {
            XCTAssertFalse(ExternalBrowserURL.isAllowed(try XCTUnwrap(URL(string: raw))), raw)
        }
    }
}
