import Foundation
import WebKit
import XCTest
@testable import BrowserCore
@testable import Shields

@MainActor
final class MarkdownStorageIntegrationTests: XCTestCase {
    func testIsolatedCookiesCacheRedirectsAndCancellation() async throws {
        let environment = ProcessInfo.processInfo.environment
        let base = URL(string: environment["QWAVE_PROBE_URL"]!)!
        let output = URL(fileURLWithPath: environment["QWAVE_PROBE_OUTPUT"]!)
        let a = try await context("A", ephemeral: false)
        let b = try await context("B", ephemeral: false)
        let privateTab = try await context("PRIVATE", ephemeral: true)
        defer { a.close(); b.close(); privateTab.close() }
        let config = MarkdownDocumentLoader.configuration(cookies: [])
        let other = MarkdownDocumentLoader.configuration(cookies: [])
        XCTAssertNil(config.urlCache)
        XCTAssertNil(config.urlCredentialStorage)
        XCTAssertFalse(config.httpCookieStorage === HTTPCookieStorage.shared)
        XCTAssertFalse(config.httpCookieStorage === other.httpCookieStorage)
        XCTAssertEqual(config.requestCachePolicy, .reloadIgnoringLocalCacheData)
        let url = base.appendingPathComponent("auth/cache.md")
        // Every context uses the same cacheable URL. Repeating A must still
        // contact the server after a private fetch, never reuse its response.
        for (fixture, marker) in [(a, "A"), (b, "B"), (privateTab, "PRIVATE"), (a, "A")] {
            await fixture.coordinator.fetchAndPresentMarkdown(url, in: fixture.web)
            try await rendered("Authenticated \(marker)", in: fixture.web)
        }
        var report: [String: Any] = [:]
        var events = try await state(base)
        let cache = events.filter { $0["path"] == "/auth/cache.md" }
        XCTAssertEqual(cache.count, 4, "Cacheable responses must not be reused between re-fetches")
        XCTAssertEqual(cache.map { $0["cookie"] ?? "" }, ["auth=A", "auth=B", "auth=PRIVATE", "auth=A"])
        XCTAssertTrue(cache.allSatisfy { $0["authorization"] == "" })
        report["cache_and_contexts"] = cache

        // A redirect-only cookie may be used inside this request's disposable
        // jar, but it must not reach localhost or be written back to WebKit.
        let redirect = base.appendingPathComponent("redirect.md")
        await a.coordinator.fetchAndPresentMarkdown(redirect, in: a.web)
        try await rendered("Redirected destination", in: a.web)
        XCTAssertEqual(a.tab.url?.host, "localhost")
        events = try await state(base)
        let hops = events.filter { ["/redirect.md", "/transient.md", "/final.md"].contains($0["path"] ?? "") }
        XCTAssertEqual(hops.count, 3)
        XCTAssertEqual(hops.first?["cookie"], "")  // /auth-only cookie does not match.
        XCTAssertEqual(hops.dropFirst().first?["cookie"], "transient=one-request")
        XCTAssertEqual(hops.last?["cookie"], "destination=A")
        let afterRedirect = await a.web.configuration.websiteDataStore.httpCookieStore.allCookies()
        XCTAssertFalse(afterRedirect.contains { $0.name == "transient" || $0.name == "responseOnly" })
        let origin = try await a.web.evaluateJavaScript("location.origin") as? String
        XCTAssertEqual(origin, "http://localhost:\(base.port!)")
        report["redirects"] = hops

        // A delayed response is cancelled after its headers have set a cookie
        // in the request jar. It cannot mutate even the initiating WebKit store.
        let slow = base.appendingPathComponent("cookie-slow.md")
        let pending = Task { await a.coordinator.fetchAndPresentMarkdown(slow, in: a.web) }
        var started = false
        for _ in 0..<100 {
            if try await state(base).contains(where: { $0["path"] == "/cookie-slow.md" }) { started = true; break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(started)
        a.coordinator.detach()
        await pending.value
        try await rendered("Redirected destination", in: a.web)
        for fixture in [a, b, privateTab] {
            let cookies = await fixture.web.configuration.websiteDataStore.httpCookieStore.allCookies()
            XCTAssertFalse(
                cookies.contains { $0.name == "late" || $0.name == "responseOnly" || $0.name == "transient" })
        }
        report["cancelled_cookie_writeback"] = false
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
    }

    func testAuthenticationAndResponseLimits() async throws {
        let base = URL(string: ProcessInfo.processInfo.environment["QWAVE_PROBE_URL"]!)!
        let (_, unauthorized) = try await MarkdownDocumentLoader.fetch(
            base.appendingPathComponent("basic.md"), cookies: [])
        XCTAssertEqual((unauthorized as? HTTPURLResponse)?.statusCode, 401)
        for path in ["oversize.md", "oversize-stream.md"] {
            do {
                _ = try await MarkdownDocumentLoader.fetch(base.appendingPathComponent(path), cookies: [])
                XCTFail("Oversized response must be rejected: \(path)")
            } catch {
                XCTAssertEqual((error as NSError).code, NSURLErrorDataLengthExceedsMaximum)
            }
        }
        let events = try await state(base)
        XCTAssertTrue(events.filter { $0["path"] == "/basic.md" }.allSatisfy { $0["authorization"] == "" })
        for url in ["file:///fixture.md", "https://user:password@example.test/file.md"] {
            do {
                _ = try await MarkdownDocumentLoader.fetch(URL(string: url)!, cookies: [])
                XCTFail("Non-web or credential-bearing URL must not start a request")
            } catch {
                XCTAssertEqual((error as NSError).code, NSURLErrorUnsupportedURL)
            }
        }
    }

    @MainActor private struct Context {
        let directory: URL
        let tab: Tab
        let web: WKWebView
        let coordinator: NavigationCoordinator
        func close() {
            coordinator.detach()
            web.stopLoading()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func context(_ marker: String, ephemeral: Bool) async throws -> Context {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("qwave-storage-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tab = Tab(containerID: UUID(), isEphemeral: ephemeral)
        let configuration = WKWebViewConfiguration()
        // Synthetic stores only, even for ordinary container models.
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.isFraudulentWebsiteWarningEnabled = false
        let web = WKWebView(frame: .zero, configuration: configuration)
        tab.attach(webView: web)
        for (name, value, domain, path, secure) in [
            ("auth", marker, "127.0.0.1", "/auth", false),
            ("destination", marker, "localhost", "/", false),
            ("wrongPath", "must-not-send", "127.0.0.1", "/other", false),
            ("secureOnly", "must-not-send", "127.0.0.1", "/", true),
        ] {
            var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
            if secure { properties[.secure] = "TRUE" }
            let cookie = HTTPCookie(properties: properties)!
            await configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        }
        let shields = ShieldsDirector(
            compiler: RuleListCompiler(store: WKContentRuleListStore(url: directory)!),
            policy: ShieldsPolicy(directory: nil))
        shields.markReady()
        let coordinator = NavigationCoordinator(
            tab: tab, shields: shields, httpsUpgrader: HTTPSFirstUpgrader(), history: nil,
            downloads: DownloadManager(directory: directory))
        return Context(directory: directory, tab: tab, web: web, coordinator: coordinator)
    }

    private func state(_ base: URL) async throws -> [[String: String]] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, _) = try await session.data(from: base.appendingPathComponent("_storage_state"))
        return try JSONDecoder().decode([[String: String]].self, from: data)
    }

    private func rendered(_ marker: String, in web: WKWebView) async throws {
        for _ in 0..<150 {
            if let text = try? await web.evaluateJavaScript("document.querySelector('.md-body')?.textContent || ''")
                as? String,
                text.contains(marker)
            {
                return
            }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTFail("Markdown did not render \(marker)")
    }
}
