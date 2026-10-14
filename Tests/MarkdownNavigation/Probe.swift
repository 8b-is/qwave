import Foundation
import WebKit
import XCTest
@testable import BrowserCore
@testable import Shields

@MainActor
final class MarkdownNavigationIntegrationTests: XCTestCase {
    func testRealMarkdownNavigationAndSupersedingPage() async throws {
        let environment = ProcessInfo.processInfo.environment
        let base = URL(string: environment["QWAVE_PROBE_URL"]!)!
        let output = URL(fileURLWithPath: environment["QWAVE_PROBE_OUTPUT"]!)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("qwave-md-navigation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let tab = Tab(isEphemeral: true)
        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.websiteDataStore = .nonPersistent()
        webConfiguration.preferences.isFraudulentWebsiteWarningEnabled = false
        let web = WKWebView(frame: .zero, configuration: webConfiguration)
        tab.attach(webView: web)
        let shields = ShieldsDirector(
            compiler: RuleListCompiler(store: WKContentRuleListStore(url: directory)!),
            policy: ShieldsPolicy(directory: nil))
        shields.markReady()
        let coordinator = NavigationCoordinator(
            tab: tab, shields: shields, httpsUpgrader: HTTPSFirstUpgrader(), history: nil,
            downloads: DownloadManager(directory: directory), session: session)
        coordinator.attach(to: web)
        defer { coordinator.detach(); web.stopLoading() }
        func document(_ marker: String) async throws -> [String: Any] {
            var last: [String: Any] = [:]
            for _ in 0..<200 {
                if let value = try? await web.evaluateJavaScript(
                    "({text:document.querySelector('.md-body')?.textContent || document.querySelector('.overlay')?.textContent || document.body?.textContent || '', origin:location.origin, base:document.baseURI, script:window.syntheticErrorScript === true, markdown:document.querySelector('.md-body') !== null})"
                ) as? [String: Any] {
                    last = value
                    if (value["text"] as? String)?.contains(marker) == true { return value }
                }
                try await Task.sleep(nanoseconds: 30_000_000)
            }
            XCTFail("Document did not render \(marker); url=\(web.url?.absoluteString ?? "nil"); observed=\(last)")
            return last
        }
        var report: [String: Any] = [:]
        let direct = base.appendingPathComponent("direct.md")
        web.load(URLRequest(url: direct))
        let valid = try await document("Active Markdown fixture")
        XCTAssertEqual(valid["markdown"] as? Bool, true)
        XCTAssertEqual(tab.url, direct)
        report["valid"] = ["document": valid, "tab_url": tab.url?.absoluteString ?? ""]

        web.load(URLRequest(url: base.appendingPathComponent("forbidden.md")))
        let error = try await document("403")
        XCTAssertEqual(error["markdown"] as? Bool, false)
        XCTAssertEqual(error["script"] as? Bool, false)
        report["http_error"] = ["document": error, "tab_url": tab.url?.absoluteString ?? ""]

        web.load(URLRequest(url: base.appendingPathComponent("slow.md")))
        var refetchStarted = false
        for _ in 0..<100 {
            let (data, _) = try await session.data(from: base.appendingPathComponent("_state"))
            let counts = try JSONSerialization.jsonObject(with: data) as! [String: Int]
            if counts["/slow.md", default: 0] >= 2 { refetchStarted = true; break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(refetchStarted, "Both WebKit's initial response and the coordinator's re-fetch must start")
        let newer = base.appendingPathComponent("newer.html")
        web.load(URLRequest(url: newer))
        _ = try await document("Newer page fixture")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let current = try await document("Newer page fixture")
        XCTAssertEqual(current["markdown"] as? Bool, false)
        XCTAssertEqual(tab.url, newer)
        report["after_delayed_response"] = [
            "document": current, "tab_url": tab.url?.absoluteString ?? "", "refetch_started": refetchStarted,
        ]
        let (countsData, _) = try await session.data(from: base.appendingPathComponent("_state"))
        let counts = try JSONSerialization.jsonObject(with: countsData) as! [String: Int]
        XCTAssertEqual(counts["/direct.md"], 2, "One WebKit request and one re-fetch; no reader replay loop")
        XCTAssertEqual(counts["/forbidden.md"], 2, "Error HTML must not trigger another network fetch")
        XCTAssertEqual(counts["/slow.md"], 2)
        XCTAssertEqual(counts["/newer.html"], 1)
        report["request_counts"] = counts
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: output)
    }
}
