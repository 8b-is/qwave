import Persistence
import SovereignCore
import WebKit
import XCTest
@testable import BrowserCore

@MainActor
final class NativeReadingControllerTests: XCTestCase {
    private let original = "こんにちは。今日は日本語の記事を読みます。"

    private final class Provider: NativeReadingProvider {
        var isReady = true
        var isBusy = false
        var calls: [[NativeReadingText]] = []
        var cancelled: [UUID] = []
        var pending: CheckedContinuation<[String], any Error>?
        var output = "Hello. Today we read an article in Japanese."
        var suspend = false
        var nextError: LocalReadingError?
        var incomplete = false

        func translate(_ entries: [NativeReadingText], to target: LocalReadingLanguage, request: UUID) async throws
            -> [String]
        {
            calls.append(entries)
            if let error = nextError { nextError = nil; throw error }
            if incomplete { return [] }
            if suspend { return try await withCheckedThrowingContinuation { pending = $0 } }
            return entries.map { _ in output }
        }
        // Deliberately do not stop delivery: the controller must reject a late
        // result even when an underlying provider ignores cancellation.
        func cancel(_ request: UUID) { cancelled.append(request) }
        func finish() {
            let continuation = pending; pending = nil
            continuation?.resume(returning: calls.last?.map { _ in output } ?? [])
        }
    }

    private func preferences() -> ReadingLanguagePreferences {
        let defaults = UserDefaults(suiteName: "native-reading-test-\(UUID())")!
        return ReadingLanguagePreferences(defaults: defaults)
    }

    private func load(_ view: WKWebView, text: String, extras: String = "") async throws {
        view.loadHTMLString(
            "<html lang='ja'><body><p id='text'>\(text)</p>\(extras)</body></html>",
            baseURL: URL(string: "https://example.test/"))
        for _ in 0..<100 {
            if !view.isLoading,
                (try? await view.evaluateJavaScript("document.getElementById('text')?.textContent") as? String) == text
            {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Fixture did not load")
    }

    private func view() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
    }

    private func until(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Bounded wait expired")
    }

    func testNativeDeliveryIsInertReversibleAndExcludesDrafts() async throws {
        let web = view(), provider = Provider()
        provider.output = "<img src=x onerror='window.executed=true'>Hello"
        try await load(
            web, text: original,
            extras:
                "<textarea>private draft</textarea><input value='private value'><div contenteditable='true'>private editor</div>"
        )
        defer { web.stopLoading() }
        let controller = NativeReadingController(webView: web, provider: provider, preferences: preferences())
        controller.scan()
        try await until { !controller.isBusy }
        XCTAssertTrue(controller.isTranslated)
        XCTAssertEqual(provider.calls.flatMap { $0.map(\.text) }, [original])
        let translated = try await web.evaluateJavaScript("document.getElementById('text').textContent") as? String
        let images = try await web.evaluateJavaScript("document.querySelectorAll('img').length") as? Int
        let pageAccess = try await web.evaluateJavaScript("typeof qwaveReading") as? String
        XCTAssertEqual(translated, provider.output); XCTAssertEqual(images, 0); XCTAssertEqual(pageAccess, "undefined")
        controller.restore(pause: true)
        try await until { !controller.isBusy }
        controller.scan()
        XCTAssertFalse(controller.isBusy)
        let restored = try await web.evaluateJavaScript("document.getElementById('text').textContent") as? String
        XCTAssertEqual(restored, original); XCTAssertEqual(provider.calls.count, 1)
        controller.suspend()
        try await until { !controller.isBusy }
        controller.scan()
        XCTAssertFalse(controller.isBusy)
    }

    func testStopRejectsDelayedDeliveryAndRetryWorks() async throws {
        let web = view(), provider = Provider()
        provider.suspend = true
        try await load(web, text: original)
        defer { provider.finish(); web.stopLoading() }
        let controller = NativeReadingController(webView: web, provider: provider, preferences: preferences())
        controller.scan()
        try await until { provider.pending != nil }
        controller.restore(pause: true)
        try await until { !controller.isBusy }
        XCTAssertFalse(provider.cancelled.isEmpty)
        provider.finish()
        await Task.yield()
        let afterStop = try await web.evaluateJavaScript("document.getElementById('text').textContent") as? String
        XCTAssertEqual(afterStop, original)
        XCTAssertFalse(controller.isTranslated)
        controller.restore(pause: false)
        try await until { !controller.isBusy }
        provider.suspend = false
        controller.scan()
        try await until { !controller.isBusy }
        XCTAssertTrue(controller.isTranslated); XCTAssertEqual(provider.calls.count, 2)
    }

    func testNavigationRejectsOldDocumentAndDoesNotCancelNewWork() async throws {
        let web = view(), provider = Provider()
        provider.suspend = true
        try await load(web, text: original)
        defer { provider.finish(); web.stopLoading() }
        let controller = NativeReadingController(webView: web, provider: provider, preferences: preferences())
        controller.scan()
        try await until { provider.pending != nil }
        controller.navigation()
        let newText = "明日の天気について新しい記事を読みます。"
        try await load(web, text: newText)
        provider.finish()
        await Task.yield()
        let afterNavigation = try await web.evaluateJavaScript("document.getElementById('text').textContent") as? String
        XCTAssertEqual(afterNavigation, newText)
        provider.suspend = false
        controller.scan()
        try await until { !controller.isBusy }
        XCTAssertTrue(controller.isTranslated)
        XCTAssertEqual(provider.calls.last?.map(\.text), [newText])
    }

    func testPreferencesAndBusyProviderPreserveOriginals() async throws {
        let web = view(), provider = Provider(), settings = preferences()
        try await load(web, text: original)
        defer { web.stopLoading() }
        let controller = NativeReadingController(webView: web, provider: provider, preferences: settings)
        settings.excludedHosts = ["example.test"]
        controller.scan(); try await until { !controller.isBusy }
        XCTAssertTrue(provider.calls.isEmpty)
        settings.excludedHosts = []; settings.excludedLanguages = ["ja"]
        controller.restore(pause: false); try await until { !controller.isBusy }
        controller.scan(); try await until { !controller.isBusy }
        XCTAssertTrue(provider.calls.isEmpty)
        settings.excludedLanguages = []; settings.language = "fr"
        controller.scan()
        XCTAssertEqual(settings.language, "fr"); XCTAssertTrue(controller.hasIssue)
        settings.language = "en"; settings.automatic = false
        controller.scan(); XCTAssertFalse(controller.isBusy)
        settings.automatic = true; provider.isBusy = true
        controller.scan(); XCTAssertFalse(controller.isBusy); XCTAssertTrue(provider.calls.isEmpty)
        let unchanged = try await web.evaluateJavaScript("document.getElementById('text').textContent") as? String
        XCTAssertEqual(unchanged, original)
    }

    func testEachPassIsBoundedAndDeferredTextIsNotLost() async throws {
        let web = view(), provider = Provider()
        try await load(web, text: original, extras: (1...6).map { "<p>\(original) 番号\($0)</p>" }.joined())
        defer { web.stopLoading() }
        let controller = NativeReadingController(webView: web, provider: provider, preferences: preferences())
        controller.scan(); try await until { !controller.isBusy }
        XCTAssertEqual(provider.calls.map(\.count), [4])
        controller.scan(); try await until { !controller.isBusy }
        XCTAssertEqual(provider.calls.map(\.count), [4, 3])
        controller.scan(); try await until { !controller.isBusy }
        XCTAssertEqual(provider.calls.count, 2)
    }

    func testBusyRaceReleasesTextAndIncompleteOutputPreservesOriginal() async throws {
        let web = view(), provider = Provider()
        try await load(web, text: original)
        defer { web.stopLoading() }
        let controller = NativeReadingController(webView: web, provider: provider, preferences: preferences())
        provider.nextError = .busy
        controller.scan(); try await until { !controller.isBusy }
        XCTAssertFalse(controller.hasIssue)
        provider.incomplete = true
        controller.scan(); try await until { !controller.isBusy }
        XCTAssertEqual(provider.calls.count, 2)
        XCTAssertTrue(controller.hasIssue); XCTAssertFalse(controller.isTranslated)
        controller.scan(); XCTAssertFalse(controller.isBusy)
        let unchanged = try await web.evaluateJavaScript("document.getElementById('text').textContent") as? String
        XCTAssertEqual(unchanged, original)
    }

    func testImmediateStopPreventsQueuedScanAndAllowsExplicitRetry() async throws {
        let web = view(), provider = Provider()
        try await load(web, text: original)
        defer { web.stopLoading() }
        let controller = NativeReadingController(webView: web, provider: provider, preferences: preferences())
        controller.scan(); controller.restore(pause: true)
        try await until { !controller.isBusy }
        XCTAssertTrue(provider.calls.isEmpty)
        controller.restore(pause: false)
        try await until { !controller.isBusy }
        controller.scan(); try await until { !controller.isBusy }
        XCTAssertTrue(controller.isTranslated)
    }
}
