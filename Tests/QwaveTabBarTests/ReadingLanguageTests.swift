import XCTest
import WebKit
import BrowserCore
import Persistence

@MainActor
final class ReadingLanguageTests: XCTestCase {
    func testRequestDoesNotReplayFormsOrLoop() {
        var request = URLRequest(url: URL(string: "https://example.com/search?q=hello")!)
        let adapted = ReadingLanguageRequest.adapted(request, mainFrame: true)
        XCTAssertNotNil(adapted?.value(forHTTPHeaderField: "Accept-Language"))
        XCTAssertNil(ReadingLanguageRequest.adapted(adapted!, mainFrame: true))
        request.httpMethod = "POST"; request.httpBody = Data("password=synthetic".utf8)
        XCTAssertNil(ReadingLanguageRequest.adapted(request, mainFrame: true))
        request.httpMethod = "GET"
        XCTAssertNil(ReadingLanguageRequest.adapted(request, mainFrame: true))
        request.httpBody = nil
        let fragment = URLRequest(url: URL(string: "https://example.com/search?q=hello#section")!)
        XCTAssertNil(ReadingLanguageRequest.adapted(fragment, mainFrame: true, currentURL: request.url))
        XCTAssertNil(ReadingLanguageRequest.adapted(request, mainFrame: false))
    }

    func testPreferenceExceptionsAndHeaderValidation() {
        let name = "QwaveReadingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let p = ReadingLanguagePreferences(defaults: defaults)
        p.language = "en-US"
        XCTAssertEqual(p.acceptLanguage, "en-US,en;q=0.9")
        XCTAssertTrue(p.permits(host: "example.com", source: "ja"))
        XCTAssertFalse(p.permits(host: "example.com", source: "en-GB"))
        p.excludedHosts = ["example.com"]
        XCTAssertFalse(p.permits(host: "EXAMPLE.com", source: "ja"))
        p.excludedLanguages = ["ja"]
        XCTAssertFalse(p.permits(host: "elsewhere.com", source: "ja-JP"))
        p.language = "en\r\nX-Test: secret"
        XCTAssertEqual(p.acceptLanguage, "en")
    }

    func testDocumentTranslationSafetyAndRestore() async throws {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 700, height: 700))
        web.loadHTMLString(
            """
            <html lang="ja"><head><title>日本語のタイトル</title></head><body><p id="one">こんにちは世界</p><button aria-label="開く">開く</button>
            <input value="private input" placeholder="検索"><textarea>private textarea</textarea>
            <pre>code text</pre><div contenteditable="true">private edit</div><p translate="no">leave me</p>
            </body></html>
            """, baseURL: URL(string: "https://example.com"))
        for _ in 0..<100 {
            if !web.isLoading, (try? await web.evaluateJavaScript("document.readyState") as? String) == "complete" {
                break
            }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        let world = WKContentWorld.world(name: "TranslationSafetyTest")
        func run(_ source: String, _ args: [String: Any] = [:]) async throws -> Any {
            try await web.callAsyncJavaScript(source, arguments: args, in: nil, contentWorld: world)
        }
        let batch = try await run(PageTranslationScript.install) as! [String: Any]
        let rows = batch["entries"] as! [[String: String]]
        let text = rows.compactMap { $0["text"] }
        XCTAssertTrue(text.contains("こんにちは世界"))
        XCTAssertTrue(text.contains("日本語のタイトル"))
        _ = try await run(
            "return qwaveReading.release(ids);", ["ids": [rows.first { $0["text"] == "日本語のタイトル" }!["id"]!]])
        let released = try await run(PageTranslationScript.install) as! [String: Any]
        XCTAssertTrue((released["entries"] as! [[String: String]]).contains { $0["text"] == "日本語のタイトル" })
        for excluded in ["private input", "private textarea", "private edit", "code text", "leave me"] {
            XCTAssertFalse(text.contains(excluded))
        }
        let doc = batch["documentID"] as! String
        let one = rows.first { $0["text"] == "こんにちは世界" }!
        let button = rows.first { $0["text"] == "開く" }!
        let translated = [["id": one["id"]!, "text": "<b>Hello</b>"], ["id": button["id"]!, "text": "Open"]]
        _ = try await run("return qwaveReading.apply(doc, rows);", ["doc": doc, "rows": translated])
        let literal = try await web.evaluateJavaScript("document.querySelector('#one').textContent") as? String
        XCTAssertEqual(literal, "<b>Hello</b>")
        let childCount = try await web.evaluateJavaScript("document.querySelector('#one').children.length") as? Int
        XCTAssertEqual(childCount, 0)
        _ = try await web.evaluateJavaScript(
            "document.querySelector('#one').textContent='Live replacement';document.body.insertAdjacentHTML('beforeend','<p>新しい内容</p>')"
        )
        let next = try await run(PageTranslationScript.install) as! [String: Any]
        XCTAssertTrue((next["entries"] as! [[String: String]]).contains { $0["text"] == "新しい内容" })
        _ = try await run("return qwaveReading.restore(true);")
        let paused = try await run(PageTranslationScript.install) as! [String: Any]
        XCTAssertEqual(paused["paused"] as? Bool, true)
        XCTAssertEqual(paused["translated"] as? Bool, false)
        let buttonOriginal = try await web.evaluateJavaScript("document.querySelector('button').textContent") as? String
        XCTAssertEqual(buttonOriginal, "開く")
        let restored = try await web.evaluateJavaScript("document.querySelector('#one').textContent") as? String
        XCTAssertEqual(restored, "Live replacement")
        let stale = try await run("return qwaveReading.apply('stale-document', rows);", ["rows": translated]) as? Bool
        XCTAssertEqual(stale, false)
    }
}
