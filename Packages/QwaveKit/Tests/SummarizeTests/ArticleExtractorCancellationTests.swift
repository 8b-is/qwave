import XCTest
import WebKit
@testable import Summarize

@MainActor
final class ArticleExtractorCancellationTests: XCTestCase {
    private let article = "The library will reopen on Monday with three quiet rooms and a new reading area."

    private func makeWaitingPage() async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.loadHTMLString("<html><body><article><p>\(article)</p></article></body></html>", baseURL: nil)
        var ready = false
        for _ in 0..<100 {
            ready =
                (try? await view.evaluateJavaScript(
                    "document.readyState === 'complete' && !!document.querySelector('article')") as? Bool) == true
            if ready { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(ready)
        // Hold only the fixture's message transport, while the real extractor
        // executes. This makes cancellation during its wait deterministic.
        _ = try await view.evaluateJavaScript(
            """
            window.originalWebkitDescriptor = Object.getOwnPropertyDescriptor(window, 'webkit');
            window.probeCount = 0;
            Object.defineProperty(window, 'webkit', { configurable: true, value: {
                messageHandlers: { probe: { postMessage: () => { window.probeCount++; } } }
            } });
            true;
            """)
        return view
    }

    func testAlreadyCancelledExtractionDoesNotRunScript() async throws {
        let view = try await makeWaitingPage()
        defer { view.stopLoading() }
        let task = Task { await ArticleExtractor.extract(from: view) }
        task.cancel()
        let start = Date()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        let count = try await view.evaluateJavaScript("window.probeCount") as? Int
        XCTAssertEqual(count, 0)
    }

    func testCancellingWaitRemovesHandlerAndAllowsNextExtraction() async throws {
        let view = try await makeWaitingPage()
        defer { view.stopLoading() }
        let task = Task { await ArticleExtractor.extract(from: view) }
        var started = false
        for _ in 0..<100 {
            started = (try await view.evaluateJavaScript("window.probeCount > 0") as? Bool) == true
            if started { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(started)
        task.cancel()
        let start = Date()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)

        _ = try await view.evaluateJavaScript(
            """
            if (window.originalWebkitDescriptor) {
                Object.defineProperty(window, 'webkit', window.originalWebkitDescriptor);
            } else {
                delete window.webkit;
            }
            true;
            """)
        // WebKit rejects registering a duplicate handler. A successful real
        // extraction also verifies that cancellation removed the old handler.
        let next = await ArticleExtractor.extract(from: view)
        XCTAssertEqual(next.flatMap(ArticleExtractor.text), article)
    }
}
