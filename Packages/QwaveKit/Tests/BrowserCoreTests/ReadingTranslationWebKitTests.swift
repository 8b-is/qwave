import XCTest
import WebKit
@testable import BrowserCore

@MainActor
final class ReadingTranslationWebKitTests: XCTestCase {
    func testTranslationIsReversibleInertAndDoesNotCaptureFormValues() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        view.loadHTMLString(
            """
            <html lang="ja"><body><p id="text">こんにちは世界</p>
            <input value="private form value"><input type="password" placeholder="secret placeholder">
            <textarea>private draft</textarea><div contenteditable="true">private editor</div>
            <p translate="no">do not translate</p></body></html>
            """, baseURL: nil)
        defer { view.stopLoading() }
        var ready = false
        for _ in 0..<50 {
            ready =
                (try? await view.evaluateJavaScript(
                    "document.readyState === 'complete' && !!document.getElementById('text')") as? Bool) == true
            if ready { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(ready)
        let world = WKContentWorld.world(name: "ReadingTranslationTest")
        let batch =
            try await view.callAsyncJavaScript(
                PageTranslationScript.install,
                arguments: ["targetLanguage": "en", "automatic": true], in: nil, contentWorld: world) as! [String: Any]
        let doc = batch["documentID"] as! String
        let entries = batch["entries"] as! [[String: String]]
        XCTAssertEqual(entries.map { $0["text"]! }, ["こんにちは世界"])
        let id = entries[0]["id"]!
        let htmlText = "<img src=x onerror='window.executed=true'>Hello world"
        let applied =
            try await view.callAsyncJavaScript(
                "return qwaveReading.apply(doc, rows);",
                arguments: ["doc": doc, "rows": [["id": id, "text": htmlText]]], in: nil, contentWorld: world) as? Bool
        XCTAssertEqual(applied, true)
        let visible = try await view.evaluateJavaScript("document.getElementById('text').textContent") as? String
        XCTAssertEqual(visible, htmlText)
        let injected = try await view.evaluateJavaScript("document.querySelectorAll('img').length") as? Int
        XCTAssertEqual(injected, 0)
        _ = try await view.callAsyncJavaScript(
            "return qwaveReading.restore(true);", arguments: [:], in: nil, contentWorld: world)
        let original = try await view.evaluateJavaScript("document.getElementById('text').textContent") as? String
        XCTAssertEqual(original, "こんにちは世界")
        _ = try await view.callAsyncJavaScript(
            "return qwaveReading.apply(doc, rows);",
            arguments: ["doc": doc, "rows": [["id": id, "text": "late result"]]], in: nil, contentWorld: world)
        let afterLateResult =
            try await view.evaluateJavaScript("document.getElementById('text').textContent") as? String
        XCTAssertEqual(afterLateResult, "こんにちは世界")
        let wrongDocument =
            try await view.callAsyncJavaScript(
                "return qwaveReading.apply('old-document', []);",
                arguments: [:], in: nil, contentWorld: world) as? Bool
        XCTAssertEqual(wrongDocument, false)
        let pageWorldAccess = try await view.evaluateJavaScript("typeof qwaveReading") as? String
        XCTAssertEqual(pageWorldAccess, "undefined")
    }
}
