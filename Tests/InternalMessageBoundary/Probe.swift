import Foundation
import WebKit
import XCTest
@testable import BrowserCore
@testable import Shields

/// Real-WebKit regression. Named-world posts in this fixture exercise native
/// authorization, not a physical user click. Synthetic page clicks must fail.
@MainActor
final class InternalMessageBoundaryTests: XCTestCase {
    func testDocumentAndSourceBoundaries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qwave-message-probe-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.isFraudulentWebsiteWarningEnabled = false
        config.setURLSchemeHandler(QwaveSchemeHandler(), forURLScheme: "qwave")
        let web = WKWebView(frame: .zero, configuration: config)
        // An ordinary tab model allows the shipped reader toolbar. Its actual
        // WebKit data store is nonpersistent and all content is synthetic.
        let tab = Tab()
        tab.attach(webView: web)
        let shields = ShieldsDirector(
            compiler: RuleListCompiler(store: WKContentRuleListStore(url: root)!),
            policy: ShieldsPolicy(directory: nil))
        shields.markReady()
        let coordinator = NavigationCoordinator(
            tab: tab, shields: shields, httpsUpgrader: HTTPSFirstUpgrader(), history: nil,
            downloads: DownloadManager(directory: root))
        coordinator.attach(to: web)
        // The forwarding sink records immutable WebKit frame metadata, then
        // invokes the production handler. No copy of its dispatch logic.
        let sink = InternalMessageProbeSink(coordinator)
        config.userContentController.removeScriptMessageHandler(forName: "qwave")
        web.configuration.userContentController.removeScriptMessageHandler(forName: "qwave")
        web.configuration.userContentController.add(sink, name: "qwave")
        var actions: [String] = []
        coordinator.onInternalAction = { action in
            switch action {
            case .submit(let value): actions.append("submit:\(value)")
            case .remember(let scope, let value): actions.append("remember:\(scope):\(value)")
            case .summarize(let range): actions.append("summarize:\(range)")
            }
        }
        defer { coordinator.detach(); web.stopLoading() }
        var report: [[String: Any]] = []
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["QWAVE_PROBE_OUTPUT"]!)
        let payloads = """
            window.webkit.messageHandlers.qwave.postMessage({type:'submit',query:'synthetic query'});
            window.webkit.messageHandlers.qwave.postMessage({type:'remember',scope:'page',text:'synthetic memory'});
            window.webkit.messageHandlers.qwave.postMessage({type:'summarize',range:'today'});
            """
        let expected = ["submit:synthetic query", "remember:page:synthetic memory", "summarize:today"]

        func ready(_ expression: String) async throws {
            for _ in 0..<200 {
                if (try? await web.evaluateJavaScript(expression)) as? Bool == true { return }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            XCTFail("Synthetic page did not become ready: \(expression)")
            throw URLError(.timedOut)
        }
        func received(_ count: Int) async throws {
            for _ in 0..<200 {
                if actions.count >= count { return }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            XCTFail("Expected \(count) actions, got \(actions)")
            throw URLError(.timedOut)
        }
        func quiet() async throws {
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertTrue(actions.isEmpty, "Untrusted actions dispatched: \(actions)")
        }
        func readerReady() async throws -> MarkdownRememberDocument {
            for _ in 0..<200 {
                if let document = coordinator.markdownRememberDocument, document.ready { return document }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            throw URLError(.timedOut)
        }
        func record(_ name: String) {
            report.append(["case": name, "actions": actions, "messages": sink.messages])
            try? JSONSerialization.data(
                withJSONObject: ["cases": report, "in_progress": true], options: [.prettyPrinted, .sortedKeys]
            ).write(to: output)
            actions.removeAll(); sink.messages.removeAll()
        }

        web.load(URLRequest(url: InternalPages.startURL))
        try await ready("document.readyState === 'complete' && !!document.getElementById('start-form')")
        _ = try await web.evaluateJavaScript(
            "document.getElementById('start-q').value='synthetic query'; document.getElementById('start-form').dispatchEvent(new Event('submit', {cancelable:true})); 0"
        )
        try await received(1)
        XCTAssertEqual(actions, [expected[0]])
        record("intended-start-form-protocol")

        web.load(URLRequest(url: InternalPages.timelineURL))
        try await ready("document.readyState === 'complete' && !!document.querySelector('[data-summarize]')")
        _ = try await web.evaluateJavaScript("document.querySelector('[data-summarize=today]').click(); 0")
        try await received(1)
        XCTAssertEqual(actions, [expected[2]])
        record("intended-timeline-button-protocol")

        let file = root.appendingPathComponent("fixture.md")
        let source = "# Synthetic local source\n\n<script>window.untrustedLocal=true;</script>"
        try source.write(to: file, atomically: true, encoding: .utf8)
        web.loadFileURL(file, allowingReadAccessTo: root)
        try await ready("document.readyState === 'complete' && !!document.querySelector('.md-body')")
        let localScriptExecuted = try await web.evaluateJavaScript("window.untrustedLocal === true") as? Bool
        XCTAssertEqual(localScriptExecuted, false)
        let localDocument = try await readerReady()
        _ = try await web.evaluateJavaScript("document.querySelector('[data-remember=page]').click(); 0")
        try await quiet()
        let pageAccess = try await web.evaluateJavaScript("typeof window.webkit.messageHandlers.qwaveRemember")
        XCTAssertEqual(pageAccess as? String, "undefined")
        record("local-reader-synthetic-click-and-page-world-denied")
        // The test acts as privileged native code in the isolated world. It
        // does not bypass the isTrusted gate in the shipped click listener.
        _ = try await web.evaluateJavaScript(
            "window.webkit.messageHandlers.qwaveRemember.postMessage({token:'\(localDocument.token)',scope:'page',text:'forged replacement'}); 0",
            in: nil, in: MarkdownRememberBridge.world)
        try await received(1)
        XCTAssertEqual(actions, ["remember:page:\(source)"])
        record("isolated-native-authorization-uses-original-page-source")
        _ = try await web.evaluateJavaScript(
            "window.webkit.messageHandlers.qwaveRemember.postMessage({token:'\(localDocument.token)',scope:'selection',text:'synthetic selection'}); 0",
            in: nil, in: MarkdownRememberBridge.world)
        try await received(1)
        XCTAssertEqual(actions, ["remember:selection:synthetic selection"])
        record("isolated-native-selection-authorization")
        _ = try await web.evaluateJavaScript(
            "window.webkit.messageHandlers.qwaveRemember.postMessage({token:'forged',scope:'page'}); 0",
            in: nil, in: MarkdownRememberBridge.world)
        try await quiet()
        record("isolated-invalid-capability-denied")

        // Simulated requests avoid network and retain a real HTTPS document
        // origin. Navigation policy is omitted here to isolate the bridge.
        web.navigationDelegate = nil
        let ordinary = URL(string: "https://synthetic.invalid/page")!
        web.loadSimulatedRequest(
            URLRequest(url: ordinary), responseHTML: "<html><body id=ordinary>synthetic</body></html>")
        try await ready("document.readyState === 'complete' && !!document.getElementById('ordinary')")
        _ = try await web.evaluateJavaScript(payloads + "0")
        try await quiet()
        XCTAssertEqual(sink.messages.count, 3)
        XCTAssertTrue(sink.messages.allSatisfy { $0["main_frame"] as? Bool == true })
        record("untrusted-https-main-frame-autopost")

        let encodedScript = try JSONSerialization.data(withJSONObject: [
            "<html><body><script>\(payloads)</script></body></html>"
        ])
        let literal = String(decoding: encodedScript, as: UTF8.self)
        _ = try await web.evaluateJavaScript(
            "var frame=document.createElement('iframe'); frame.srcdoc=\(literal)[0]; document.body.appendChild(frame); 0"
        )
        try await quiet()
        XCTAssertEqual(sink.messages.count, 3)
        XCTAssertTrue(sink.messages.allSatisfy { $0["main_frame"] as? Bool == false })
        record("untrusted-srcdoc-subframe-autopost")

        // Exercise the real Markdown fetch, compiler and presenter with a
        // loopback response containing raw HTML; no real remote site is used.
        let remote = URL(string: ProcessInfo.processInfo.environment["QWAVE_PROBE_URL"]!)!
        web.navigationDelegate = coordinator
        await coordinator.fetchAndPresentMarkdown(remote, in: web)
        _ = try await readerReady()
        try await quiet()
        XCTAssertEqual(sink.messages.count, 3)
        XCTAssertEqual(web.url, remote)
        record("remote-raw-markdown-script-denied")

        let beforeFragment = try await readerReady()
        _ = try await web.evaluateJavaScript("location.hash='reader-section'; 0")
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(coordinator.markdownRememberDocument?.token, beforeFragment.token)
        _ = try await web.evaluateJavaScript(
            "window.webkit.messageHandlers.qwaveRemember.postMessage({token:'\(beforeFragment.token)',scope:'page'}); 0",
            in: nil, in: MarkdownRememberBridge.world)
        try await received(1)
        XCTAssertEqual(actions, ["remember:page:\(beforeFragment.source)"])
        record("reader-remains-authorized-after-fragment-navigation")

        // A body-type guard is a useful negative control. It does not impose
        // origin, frame, attachment or shell-selection checks.
        _ = try await web.evaluateJavaScript(
            "window.webkit.messageHandlers.qwave.postMessage({type:'submit',query:123}); window.webkit.messageHandlers.qwave.postMessage({type:'unknown'}); 0"
        )
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(sink.messages.count, 2)
        record("malformed-and-unknown-rejected-control")

        web.load(URLRequest(url: InternalPages.startURL))
        try await ready("document.readyState === 'complete' && location.href === 'qwave://start'")
        let beforeReload = try XCTUnwrap(coordinator.captureInternalActionSource())
        XCTAssertTrue(beforeReload.isCurrent(selectedTab: tab))
        XCTAssertFalse(beforeReload.isCurrent(selectedTab: Tab()))
        web.reload()
        for _ in 0..<200 where beforeReload.isCurrent(selectedTab: tab) {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertFalse(beforeReload.isCurrent(selectedTab: tab))
        try await ready("document.readyState === 'complete' && location.href === 'qwave://start'")
        let current = try XCTUnwrap(coordinator.captureInternalActionSource())
        XCTAssertTrue(current.isCurrent(selectedTab: tab))
        record("shell-source-rejects-other-tab-and-same-url-navigation")
        _ = try await web.evaluateJavaScript(
            "window.webkit.messageHandlers.qwave.postMessage({type:'summarize',range:'today'}); window.webkit.messageHandlers.qwave.postMessage({type:'submit',query:'x'.repeat(4097)}); 0"
        )
        try await quiet()
        record("start-role-mismatch-and-oversized-query-denied")
        _ = try await web.evaluateJavaScript(
            "window.webkit.messageHandlers.qwave.postMessage({type:'submit',query:'synthetic query'}); 0")
        try await received(1)
        let retainedMessage = try XCTUnwrap(sink.retainedMessages.last)
        record("start-still-works-after-reload")
        let replacementConfig = WKWebViewConfiguration()
        replacementConfig.websiteDataStore = .nonPersistent()
        let replacement = WKWebView(frame: .zero, configuration: replacementConfig)
        tab.attach(webView: replacement)
        coordinator.attach(to: replacement)
        coordinator.userContentController(web.configuration.userContentController, didReceive: retainedMessage)
        try await quiet()
        XCTAssertFalse(current.isCurrent(selectedTab: tab))
        let removed = try await web.evaluateJavaScript("typeof window.webkit?.messageHandlers?.qwave")
        XCTAssertEqual(removed as? String, "undefined")
        record("replaced-old-view-handler-removed-and-buffered-message-denied")
        coordinator.detach()
        coordinator.userContentController(web.configuration.userContentController, didReceive: retainedMessage)
        try await quiet()
        XCTAssertNil(coordinator.captureInternalActionSource())
        record("detached-buffered-message-denied")

        try JSONSerialization.data(
            withJSONObject: ["cases": report, "baseline_only": false, "shell_side_effects_executed": false],
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: output)
    }
}

@MainActor
private final class InternalMessageProbeSink: NSObject, WKScriptMessageHandler {
    let coordinator: NavigationCoordinator
    var messages: [[String: Any]] = []
    var retainedMessages: [WKScriptMessage] = []
    init(_ coordinator: NavigationCoordinator) { self.coordinator = coordinator }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        retainedMessages.append(message)
        messages.append([
            "type": (message.body as? [String: Any])?["type"] as? String ?? "",
            "main_frame": message.frameInfo.isMainFrame,
            "frame_url": message.frameInfo.request.url?.absoluteString ?? "",
            "web_view_url": message.webView?.url?.absoluteString ?? "",
            "security_origin":
                "\(message.frameInfo.securityOrigin.protocol)://\(message.frameInfo.securityOrigin.host):\(message.frameInfo.securityOrigin.port)",
            "current_tab_view": message.webView === coordinator.tab?.webView,
        ])
        coordinator.userContentController(controller, didReceive: message)
    }
}
