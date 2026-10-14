import Foundation
import WebKit
import XCTest

@testable import BrowserCore
@testable import Shields

@MainActor
final class MarkdownLifecycleTests: XCTestCase {
    func testLaterMarkdownRequestWins() async throws {
        let fixture = try await context()
        defer { fixture.close() }
        let slow = fixture.url("slow")
        let pending = Task { await fixture.coordinator.fetchAndPresentMarkdown(slow, in: fixture.web) }
        try await started(slow)
        let latest = fixture.url("latest")
        await fixture.coordinator.fetchAndPresentMarkdown(latest, in: fixture.web)
        await pending.value
        try await rendered("Latest Markdown", in: fixture.web)
        XCTAssertEqual(fixture.tab.url, latest)
        XCTAssertTrue(LifecycleTransport.events.stopped(slow))
    }

    func testSupersededFailureDoesNotReplaceNewDocument() async throws {
        let fixture = try await context()
        defer { fixture.close() }
        let slow = fixture.url("slow-failure")
        let pending = Task { await fixture.coordinator.fetchAndPresentMarkdown(slow, in: fixture.web) }
        try await started(slow)
        await fixture.coordinator.fetchAndPresentMarkdown(fixture.url("latest"), in: fixture.web)
        await pending.value
        try await rendered("Latest Markdown", in: fixture.web)
        XCTAssertEqual(fixture.tab.title, "latest.md")
    }

    func testMainFrameNavigationCancelsPendingFetch() async throws {
        let fixture = try await context()
        defer { fixture.close() }
        fixture.coordinator.attach(to: fixture.web)
        let slow = fixture.url("slow")
        let pending = Task { await fixture.coordinator.fetchAndPresentMarkdown(slow, in: fixture.web) }
        try await started(slow)
        // An actual WebKit navigation-policy callback, not a direct call to
        // the invalidation helper. The about:blank base prevents external I/O.
        fixture.web.loadHTMLString("<h1>Newer document</h1>", baseURL: nil)
        try await rendered("Newer document", in: fixture.web)
        await pending.value
        try await rendered("Newer document", in: fixture.web)
        XCTAssertTrue(LifecycleTransport.events.stopped(slow))
        XCTAssertNotEqual(fixture.tab.url, slow)
    }

    func testDetachCancelsFetchWithoutErrorPage() async throws {
        let fixture = try await context()
        defer { fixture.close() }
        let slow = fixture.url("slow")
        let pending = Task { await fixture.coordinator.fetchAndPresentMarkdown(slow, in: fixture.web) }
        try await started(slow)
        fixture.coordinator.detach()
        await pending.value
        try await rendered("Original document", in: fixture.web)
        XCTAssertEqual(fixture.tab.title, "Original")
        XCTAssertTrue(LifecycleTransport.events.stopped(slow))
        let ignored = fixture.url("ignored")
        await fixture.coordinator.fetchAndPresentMarkdown(ignored, in: fixture.web)
        XCTAssertFalse(LifecycleTransport.events.started(ignored))
    }

    func testReplacedWebViewRejectsCompletion() async throws {
        let fixture = try await context()
        defer { fixture.close() }
        let slow = fixture.url("slow")
        let pending = Task { await fixture.coordinator.fetchAndPresentMarkdown(slow, in: fixture.web) }
        try await started(slow)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let replacement = WKWebView(frame: .zero, configuration: config)
        fixture.tab.attach(webView: replacement)
        await pending.value
        try await rendered("Original document", in: fixture.web)
        XCTAssertEqual(fixture.tab.title, "Original")
        XCTAssertTrue(fixture.tab.webView === replacement)
    }

    func testCallerCancellationDoesNotShowErrorPage() async throws {
        let fixture = try await context()
        defer { fixture.close() }
        let slow = fixture.url("slow")
        let pending = Task { await fixture.coordinator.fetchAndPresentMarkdown(slow, in: fixture.web) }
        try await started(slow)
        pending.cancel()
        await pending.value
        try await rendered("Original document", in: fixture.web)
        XCTAssertEqual(fixture.tab.title, "Original")
        XCTAssertTrue(LifecycleTransport.events.stopped(slow))
    }

    func testOldViewCannotCancelNewViewFetch() async throws {
        let fixture = try await context()
        defer { fixture.close() }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let replacement = WKWebView(frame: .zero, configuration: config)
        defer { replacement.stopLoading() }
        fixture.tab.attach(webView: replacement)
        let active = fixture.url("slow")
        let pending = Task { await fixture.coordinator.fetchAndPresentMarkdown(active, in: replacement) }
        try await started(active)
        let ignored = fixture.url("ignored-old-view")
        await fixture.coordinator.fetchAndPresentMarkdown(ignored, in: fixture.web)
        await pending.value
        try await rendered("Stale Markdown", in: replacement)
        XCTAssertFalse(LifecycleTransport.events.started(ignored))
        XCTAssertEqual(fixture.tab.url, active)
    }

    @MainActor
    private struct Context {
        let directory: URL
        let tab: Tab
        let web: WKWebView
        let coordinator: NavigationCoordinator
        let session: URLSession
        func url(_ name: String) -> URL {
            URL(string: "https://lifecycle.example/\(name).md?fixture=\(tab.id)")!
        }
        func close() {
            coordinator.detach()
            web.stopLoading()
            session.invalidateAndCancel()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func context() async throws -> Context {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("qwave-md-lifecycle-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.protocolClasses = [LifecycleTransport.self]
        let session = URLSession(configuration: config)
        let tab = Tab(isEphemeral: true)
        let webConfig = WKWebViewConfiguration()
        webConfig.websiteDataStore = .nonPersistent()
        webConfig.preferences.isFraudulentWebsiteWarningEnabled = false
        let web = WKWebView(frame: .zero, configuration: webConfig)
        tab.attach(webView: web)
        let shields = ShieldsDirector(
            compiler: RuleListCompiler(store: WKContentRuleListStore(url: directory)!),
            policy: ShieldsPolicy(directory: nil))
        shields.markReady()
        let coordinator = NavigationCoordinator(
            tab: tab, shields: shields, httpsUpgrader: HTTPSFirstUpgrader(), history: nil,
            downloads: DownloadManager(directory: directory), session: session)
        web.loadHTMLString("<h1>Original document</h1>", baseURL: nil)
        try await rendered("Original document", in: web)
        tab.title = "Original"
        return Context(directory: directory, tab: tab, web: web, coordinator: coordinator, session: session)
    }

    private func started(_ url: URL) async throws {
        for _ in 0..<100 {
            if LifecycleTransport.events.started(url) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("The synthetic transport did not start")
    }

    private func rendered(_ marker: String, in web: WKWebView) async throws {
        for _ in 0..<100 {
            if let text = try? await web.evaluateJavaScript("document.body?.textContent || ''") as? String,
                text.contains(marker), !web.isLoading
            {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Expected document: \(marker)")
    }
}

private final class LifecycleTransport: URLProtocol {
    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var starts = Set<URL>()
        private var stops = Set<URL>()
        func start(_ url: URL) { lock.withLock { _ = starts.insert(url) } }
        func stop(_ url: URL) { lock.withLock { _ = stops.insert(url) } }
        func started(_ url: URL) -> Bool { lock.withLock { starts.contains(url) } }
        func stopped(_ url: URL) -> Bool { lock.withLock { stops.contains(url) } }
    }
    // Only this synthetic delivery crosses queues. The protocol's mutable
    // cancellation flag and the event recorder are protected by their locks.
    private final class Delivery: @unchecked Sendable {
        let transport: LifecycleTransport
        init(_ transport: LifecycleTransport) { self.transport = transport }
        func run() { transport.deliver() }
    }
    static let events = Events()
    private let lock = NSLock()
    private var isStopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.events.start(url)
        let delivery = Delivery(self)
        DispatchQueue.global().asyncAfter(deadline: .now() + (url.path.contains("slow") ? 0.4 : 0.01)) {
            delivery.run()
        }
    }
    private func deliver() {
        let url = request.url!
        guard !lock.withLock({ isStopped }) else { return }
        if url.path.contains("failure") {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/markdown"])!
        let body = url.path.contains("slow") ? "# Stale Markdown" : "# Latest Markdown"
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        lock.withLock { isStopped = true }
        if let url = request.url { Self.events.stop(url) }
    }
}
