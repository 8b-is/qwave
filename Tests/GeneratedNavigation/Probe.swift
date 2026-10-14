import Foundation
import WebKit
import XCTest
@testable import BrowserCore
@testable import Shields

@MainActor
final class GeneratedPageNavigationIntegrationTests: XCTestCase {
    func testGeneratedPagesKeepTheirDocumentWithoutReplay() async throws {
        let base = URL(string: ProcessInfo.processInfo.environment["QWAVE_PROBE_URL"]!)!
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["QWAVE_PROBE_OUTPUT"]!)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qwave-generated-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let markdown = root.appendingPathComponent("fixture.md")
        try """
        # Local fixture
        [Next](next.html)
        <script>window.untrustedLocal = true;</script>
        <img src="missing" onerror="window.untrustedLocal=true">
        """.write(to: markdown, atomically: true, encoding: .utf8)
        let forged = root.appendingPathComponent("forged.md")
        try FileManager.default.copyItem(at: markdown, to: forged)
        let listing = root.appendingPathComponent("listing", isDirectory: true)
        try FileManager.default.createDirectory(at: listing, withIntermediateDirectories: true)
        try "synthetic".write(to: listing.appendingPathComponent("example.txt"), atomically: true, encoding: .utf8)
        let readme = root.appendingPathComponent("readme", isDirectory: true)
        try FileManager.default.createDirectory(at: readme, withIntermediateDirectories: true)
        try "# Directory README".write(
            to: readme.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let missing = root.appendingPathComponent("missing.md")
        var report: [[String: Any]] = []
        let cases: [(String, URL, String, URL)] = [
            ("local-markdown", markdown, "Local fixture", markdown),
            ("forged-local-marker", forged, "Local fixture", forged),
            ("directory-listing", listing, "example.txt", listing),
            ("directory-readme", readme, "Directory README", readme.appendingPathComponent("README.md")),
            ("missing-file", missing, "404", missing),
            (
                "http-error", base.appendingPathComponent("not-found.html"), "404",
                base.appendingPathComponent("not-found.html")
            ),
            (
                "connection-error", base.appendingPathComponent("connection-failure.html"), "Lost in the Math",
                base.appendingPathComponent("connection-failure.html")
            ),
        ]
        for (name, url, expected, documentURL) in cases {
            let tab = Tab(isEphemeral: true)
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.preferences.isFraudulentWebsiteWarningEnabled = false
            let web = WKWebView(frame: .zero, configuration: configuration)
            tab.attach(webView: web)
            let shields = ShieldsDirector(
                compiler: RuleListCompiler(store: WKContentRuleListStore(url: root)!),
                policy: ShieldsPolicy(directory: nil))
            shields.markReady()
            let coordinator = NavigationCoordinator(
                tab: tab, shields: shields, httpsUpgrader: HTTPSFirstUpgrader(), history: nil,
                downloads: DownloadManager(directory: root))
            coordinator.attach(to: web)
            // Forward real WebKit callbacks, cutting off a broken recursive
            // presenter after 16 actions so baseline probes stay bounded.
            let guardrail = NavigationGuardrail(coordinator)
            web.navigationDelegate = guardrail
            if name == "connection-error" {
                // Deterministic timeout callback; subsequent HTML navigation
                // and policy callbacks are real WebKit. No real timeout claim.
                let error = NSError(
                    domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [NSURLErrorFailingURLErrorKey: url])
                coordinator.webView(web, didFailProvisionalNavigation: nil, withError: error)
            } else if name == "forged-local-marker" {
                var request = URLRequest(url: url)
                request.setValue("forged", forHTTPHeaderField: "X-Qwave-Local-Document")
                web.loadFileRequest(request, allowingReadAccessTo: root)
            } else if url.isFileURL {
                web.loadFileURL(url, allowingReadAccessTo: root)
            } else {
                web.load(URLRequest(url: url))
            }
            var document: [String: Any] = [:]
            for _ in 0..<100 {
                if let value = try? await web.evaluateJavaScript(
                    "({text: document.body?.textContent || '', base: document.baseURI, script: window.untrustedLocal === true || window.syntheticErrorScript === true, link: document.querySelector('.md-body a')?.href || '', markdown: document.querySelector('.md-body') !== null})"
                ) as? [String: Any] {
                    document = value
                    if (value["text"] as? String)?.contains(expected) == true { break }
                }
                if guardrail.stopped { break }
                try await Task.sleep(nanoseconds: 30_000_000)
            }
            let rendered = (document["text"] as? String)?.contains(expected) == true
            report.append([
                "case": name, "rendered": rendered, "document": document, "tab_url": tab.url?.absoluteString ?? "",
                "expected_url": documentURL.absoluteString, "actions": guardrail.actions, "cutoff": guardrail.stopped,
            ])
            XCTAssertTrue(rendered, name + " failed to render expected generated document")
            XCTAssertFalse(guardrail.stopped, name + " recursively navigated")
            XCTAssertEqual(document["script"] as? Bool, false, name)
            XCTAssertEqual(document["base"] as? String, documentURL.absoluteString, name)
            XCTAssertEqual(tab.url, documentURL, name)
            if name == "local-markdown" {
                XCTAssertEqual(document["link"] as? String, root.appendingPathComponent("next.html").absoluteString)
            }
            if name == "local-markdown" {
                // Reload retains the old simulated request. Its consumed token
                // must not let changed local source bypass compilation.
                try "# Reloaded local fixture\n<script>window.untrustedLocal=true;</script>".write(
                    to: markdown, atomically: true, encoding: .utf8)
                web.reload()
                var reloaded: [String: Any] = [:]
                for _ in 0..<100 {
                    if let value = try? await web.evaluateJavaScript(
                        "({text: document.querySelector('.md-body')?.textContent || '', script: window.untrustedLocal === true, base: document.baseURI})"
                    ) as? [String: Any] {
                        reloaded = value
                        if (value["text"] as? String)?.contains("Reloaded local fixture") == true { break }
                    }
                    if guardrail.stopped { break }
                    try await Task.sleep(nanoseconds: 30_000_000)
                }
                XCTAssertTrue((reloaded["text"] as? String)?.contains("Reloaded local fixture") == true)
                XCTAssertEqual(reloaded["script"] as? Bool, false)
                XCTAssertEqual(reloaded["base"] as? String, markdown.absoluteString)
                XCTAssertEqual(tab.url, markdown)
                XCTAssertFalse(guardrail.stopped)
                report.append([
                    "case": "reload-changed-local-markdown", "document": reloaded, "actions": guardrail.actions,
                    "cutoff": guardrail.stopped,
                ])
            }
            coordinator.detach()
            web.stopLoading()
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil; configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, _) = try await session.data(from: base.appendingPathComponent("_state"))
        let counts = try JSONDecoder().decode([String: Int].self, from: data)
        XCTAssertEqual(counts["/not-found.html"], 1)
        XCTAssertEqual(counts["/connection-failure.html", default: 0], 0)
        try JSONSerialization.data(
            withJSONObject: ["cases": report, "requests": counts], options: [.prettyPrinted, .sortedKeys]
        ).write(to: output)
    }
}

@MainActor
private final class NavigationGuardrail: NSObject, WKNavigationDelegate {
    let coordinator: NavigationCoordinator
    var actions: [String] = []
    var stopped = false
    init(_ coordinator: NavigationCoordinator) { self.coordinator = coordinator }
    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        actions.append(action.request.url?.absoluteString ?? "nil")
        if actions.count > 16 { stopped = true; decisionHandler(.cancel, preferences); return }
        coordinator.webView(
            webView, decidePolicyFor: action, preferences: preferences, decisionHandler: decisionHandler)
    }
    func webView(
        _ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        coordinator.webView(webView, decidePolicyFor: response, decisionHandler: decisionHandler)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        coordinator.webView(webView, didFinish: navigation)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        coordinator.webView(webView, didFail: navigation, withError: error)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        coordinator.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
    }
}
