import XCTest
@testable import BrowserCore

@MainActor
final class MarkdownRememberDocumentTests: XCTestCase {
    func testCapabilityRequiresCompletedDocumentAndMatchingToken() {
        var document = MarkdownRememberDocument(url: URL(string: "https://example.test/a.md")!, source: "original")
        let body: [String: Any] = ["token": document.token, "scope": "page"]
        XCTAssertNil(document.action(body: body))
        document.ready = true
        XCTAssertNil(document.action(body: ["token": "forged", "scope": "page"]))
        XCTAssertEqual(document.action(body: body), .remember(scope: "page", text: "original"))
    }

    func testPageSourceCannotBeReplacedByMessageText() {
        var document = MarkdownRememberDocument(url: URL(string: "file:///tmp/a.md")!, source: "original")
        document.ready = true
        XCTAssertEqual(
            document.action(body: ["token": document.token, "scope": "page", "text": "replacement"]),
            .remember(scope: "page", text: "original"))
    }

    func testSelectionFallbackAndBounds() {
        var document = MarkdownRememberDocument(url: URL(string: "https://example.test/a.md")!, source: "original")
        document.ready = true
        XCTAssertEqual(
            document.action(body: ["token": document.token, "scope": "selection", "text": "selected"]),
            .remember(scope: "selection", text: "selected"))
        XCTAssertEqual(
            document.action(body: ["token": document.token, "scope": "selection", "text": ""]),
            .remember(scope: "selection", text: "original"))
        XCTAssertNil(document.action(body: ["token": document.token, "scope": "arbitrary"]))
        XCTAssertNil(
            document.action(body: [
                "token": document.token, "scope": "selection",
                "text": String(repeating: "x", count: MarkdownRememberBridge.maxSelectionCharacters + 1),
            ]))
    }

    func testNewDocumentDoesNotAcceptOldCapability() {
        let url = URL(string: "https://example.test/a.md")!
        let old = MarkdownRememberDocument(url: url, source: "old")
        var new = MarkdownRememberDocument(url: url, source: "new")
        new.ready = true
        XCTAssertNil(new.action(body: ["token": old.token, "scope": "page"]))
    }
}
