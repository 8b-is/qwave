import AppKit
import WebKit
import XCTest
@testable import BrowserCore
@testable import Shields

/// Native AppKit input through a visible WebKit window, using only synthetic
/// documents and nonpersistent storage. No model, Keychain or user app state.
@MainActor
final class InternalMessageNativeInputTests: XCTestCase {
    func testTrustedReaderControls() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qwave-native-input-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let previousApplication = NSWorkspace.shared.frontmostApplication
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1100, height: 760),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Qwave synthetic native-input validation"
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.isFraudulentWebsiteWarningEnabled = false
        configuration.setURLSchemeHandler(QwaveSchemeHandler(), forURLScheme: "qwave")
        let web = WKWebView(frame: window.contentView!.bounds, configuration: configuration)
        web.autoresizingMask = [.width, .height]
        window.contentView = web
        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        defer {
            web.stopLoading()
            window.orderOut(nil)
            previousApplication?.activate(options: [])
        }
        let tab = Tab()
        tab.attach(webView: web)
        let shields = ShieldsDirector(
            compiler: RuleListCompiler(store: WKContentRuleListStore(url: root)!),
            policy: ShieldsPolicy(directory: nil))
        shields.markReady()
        let coordinator = NavigationCoordinator(
            tab: tab, shields: shields, httpsUpgrader: HTTPSFirstUpgrader(),
            history: nil, downloads: DownloadManager(directory: root))
        coordinator.attach(to: web)
        defer { coordinator.detach() }
        var actions: [String] = []
        coordinator.onInternalAction = { action in
            switch action {
            case .submit(let query): actions.append("submit:\(query)")
            case .summarize(let range): actions.append("summarize:\(range)")
            case .remember(let scope, let text): actions.append("remember:\(scope):\(text)")
            }
        }
        var cases: [[String: Any]] = []
        func ready(_ expression: String) async throws {
            for _ in 0..<200 {
                if (try? await web.evaluateJavaScript(expression)) as? Bool == true { return }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            throw NSError(domain: "NativeInputPageNotReady", code: 1, userInfo: [NSLocalizedDescriptionKey: expression])
        }
        func nativeClick(_ selector: String, expected: String, name: String) async throws {
            let literal = String(decoding: try JSONEncoder().encode(selector), as: UTF8.self)
            let coordinates =
                try await web.evaluateJavaScript(
                    """
                    (() => {
                      const button = document.querySelector(\(literal));
                      button.scrollIntoView({block:'center'});
                      window.__qwaveNativeClickTrusted = null;
                      button.addEventListener('click', event => {
                        window.__qwaveNativeClickTrusted = event.isTrusted;
                      }, {once:true});
                      const rect = button.getBoundingClientRect();
                      return [rect.x + rect.width / 2, rect.y + rect.height / 2];
                    })()
                    """) as! [Double]
            let point = web.convert(
                NSPoint(x: coordinates[0], y: web.isFlipped ? coordinates[1] : web.bounds.height - coordinates[1]),
                to: nil)
            let target = try XCTUnwrap(web.hitTest(web.convert(point, from: nil)))
            print("Native input target: \(type(of: target)), point=\(point), viewport=\(web.bounds)")
            for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(
                    with: kind, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: kind == .leftMouseDown ? 1 : 0)!
                if kind == .leftMouseDown { target.mouseDown(with: event) } else { target.mouseUp(with: event) }
            }
            for _ in 0..<200 {
                if !actions.isEmpty { break }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            let trusted = try await web.evaluateJavaScript("window.__qwaveNativeClickTrusted === true") as? Bool
            XCTAssertEqual(trusted, true, name)
            XCTAssertEqual(actions, [expected], name)
            cases.append(["case": name, "event_is_trusted": trusted == true, "actions": actions])
            actions.removeAll()
        }
        web.load(URLRequest(url: InternalPages.startURL))
        try await ready("document.readyState === 'complete' && !!document.querySelector('#start-form button')")
        _ = try await web.evaluateJavaScript("document.getElementById('start-q').value='native synthetic query'; 0")
        try await nativeClick("#start-form button", expected: "submit:native synthetic query", name: "start-submit")
        web.load(URLRequest(url: InternalPages.timelineURL))
        try await ready("document.readyState === 'complete' && !!document.querySelector('[data-summarize]')")
        for range in ["today", "week", "all"] {
            try await nativeClick(
                "[data-summarize=\(range)]", expected: "summarize:\(range)", name: "timeline-\(range)")
        }
        let local = root.appendingPathComponent("fixture.md")
        let localSource = "# Native local fixture\n\nSynthetic selection text."
        try localSource.write(to: local, atomically: true, encoding: .utf8)
        let remote = URL(string: ProcessInfo.processInfo.environment["QWAVE_PROBE_URL"]!)!
        for (kind, url) in [("local", local), ("remote", remote)] {
            if url.isFileURL {
                web.loadFileURL(url, allowingReadAccessTo: root)
            } else {
                await coordinator.fetchAndPresentMarkdown(url, in: web)
            }
            try await ready("document.readyState === 'complete' && !!document.querySelector('[data-remember=page]')")
            for _ in 0..<200 {
                if coordinator.markdownRememberDocument?.ready == true { break }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            let source = try XCTUnwrap(coordinator.markdownRememberDocument?.source)
            try await nativeClick(
                "[data-remember=page]", expected: "remember:page:\(source)", name: "\(kind)-remember-page")
            let selection =
                try await web.evaluateJavaScript(
                    """
                    (() => { const range = document.createRange(); range.selectNodeContents(document.querySelector('.md-body h1'));
                      const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
                      return selection.toString(); })()
                    """) as! String
            try await nativeClick(
                "[data-remember=selection]", expected: "remember:selection:\(selection)",
                name: "\(kind)-remember-selection")
            _ = try await web.evaluateJavaScript("location.hash='native-fragment'; 0")
            try await Task.sleep(nanoseconds: 200_000_000)
            try await nativeClick("[data-remember=page]", expected: "remember:page:\(source)", name: "\(kind)-fragment")
            web.reload()
            try await Task.sleep(nanoseconds: 500_000_000)
            try await ready("document.readyState === 'complete' && !!document.querySelector('[data-remember=page]')")
            try await nativeClick("[data-remember=page]", expected: "remember:page:\(source)", name: "\(kind)-reload")
        }
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["QWAVE_PROBE_OUTPUT"]!)
        try JSONSerialization.data(
            withJSONObject: [
                "cases": cases, "input": "AppKit NSEvent delivered to the test window",
                "storage": "nonpersistent synthetic fixture", "user_app_launched": false,
                "production_coordinator": true, "model_or_keychain_access": false,
            ], options: [.prettyPrinted, .sortedKeys]
        ).write(to: output)
    }
}
