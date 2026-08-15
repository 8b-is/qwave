import Foundation
import WebKit
import XCTest

@testable import WebExtensions

/// End-to-end tests that drive a **real `WKWebView`**, load a real document,
/// and assert what that document's *own* scripts can and cannot reach.
///
/// Every other test in this target calls `router.handle(...)` in process, which
/// cannot observe a content-world mistake: the world only exists inside WebKit.
/// These tests exist because a bridge installed into the wrong world type-checks,
/// unit-tests green, and silently disables the feature at runtime.
@MainActor
final class ExtensionBridgeWorldTests: XCTestCase {

    // MARK: - Fixtures

    private func makeRouter() -> ExtensionMessageRouter {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwave-ext-world-\(UUID().uuidString)", isDirectory: true)
        let defaults = UserDefaults(suiteName: "qwave-test-world-\(UUID().uuidString)")!
        return ExtensionMessageRouter(
            registry: WebExtensionRegistry(defaults: defaults),
            storage: ExtensionStorageService(directory: dir)
        )
    }

    /// Builds a web view wired exactly the way a bridge surface is wired: the
    /// `qwaveExtension` message handler and the `browser.*` user script both in
    /// `bridgeWorld`.
    private func makeWebView(
        bridgeWorld: WKContentWorld,
        router: ExtensionMessageRouter,
        contentScripts: [WKUserScript] = []
    ) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let controller = configuration.userContentController
        controller.add(
            router,
            contentWorld: bridgeWorld,
            name: BrowserBridgeScript.messageHandlerName
        )
        controller.addUserScript(
            WKUserScript(
                source: BrowserBridgeScript.source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: bridgeWorld
            )
        )
        for script in contentScripts {
            controller.addUserScript(script)
        }
        return WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), configuration: configuration)
    }

    /// A document whose own inline script probes the bridge and, if it is
    /// reachable, drives a full `set` -> `get` round trip through native code.
    /// A reply that lands in the wrong world leaves `__roundTrip` at `pending`.
    private static let probeDocument = """
        <html><body><script>
        window.__typeofBrowser = typeof window.browser;
        window.__typeofHandler = typeof (window.webkit && window.webkit.messageHandlers
            && window.webkit.messageHandlers.qwaveExtension);
        window.__typeofMarker = typeof window.__qwaveContentScriptMarker;
        window.__roundTrip = 'pending';
        if (typeof window.browser === 'object') {
          window.browser.storage.local.set({ theme: 'dark' })
            .then(function () { return window.browser.storage.local.get('theme'); })
            .then(function (v) { window.__roundTrip = 'theme=' + (v && v.theme); })
            .catch(function (e) { window.__roundTrip = 'error:' + e; });
        } else {
          window.__roundTrip = 'no-bridge';
        }
        window.__probeReady = true;
        </script></body></html>
        """

    // MARK: - Evaluation helpers

    /// Evaluates `js` in `world` and returns it stringified. Only `String`
    /// crosses the continuation, so nothing non-`Sendable` escapes the web view.
    private func evalString(_ webView: WKWebView, _ world: WKContentWorld, _ js: String) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
            webView.evaluateJavaScript("String(\(js))", in: nil, in: world) { result in
                switch result {
                case .success(let value):
                    continuation.resume(returning: (value as? String) ?? String(describing: value))
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Polls `js` in `world` until it stringifies to `expected`, or the deadline
    /// passes. Returns the last value seen so a failure message can show it.
    @discardableResult
    private func poll(
        _ webView: WKWebView,
        _ world: WKContentWorld,
        _ js: String,
        until expected: String,
        timeout: TimeInterval = 15
    ) async -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var last = "<never evaluated>"
        while Date() < deadline {
            if let value = try? await evalString(webView, world, js) {
                last = value
                if value == expected { return value }
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return last
    }

    /// Loads the probe document and waits for its inline script to have run.
    private func loadProbe(into webView: WKWebView) async throws {
        webView.loadHTMLString(Self.probeDocument, baseURL: nil)
        let ready = await poll(webView, .page, "window.__probeReady === true", until: "true")
        try XCTSkipUnless(
            ready == "true",
            "WKWebView could not load a document in this test process; see residualRisk."
        )
    }

    // MARK: - The popup surface

    /// The extension's own `popup.html` runs its scripts in `WKContentWorld.page`.
    /// If the bridge is installed anywhere else, the popup sees no `browser.*`
    /// and no message handler, and every real extension popup throws.
    func testExtensionPageDocumentCanReachTheBridge() async throws {
        let router = makeRouter()
        let webView = makeWebView(bridgeWorld: ExtensionContentWorld.extensionPage, router: router)
        try await loadProbe(into: webView)

        let browserType = try await evalString(webView, .page, "window.__typeofBrowser")
        XCTAssertEqual(
            browserType, "object",
            "popup.html's own script must see window.browser; got '\(browserType)'")

        let handlerType = try await evalString(webView, .page, "window.__typeofHandler")
        XCTAssertEqual(
            handlerType, "object",
            "popup.html's own script must see the qwaveExtension message handler; got '\(handlerType)'")
    }

    /// The reply half: a native response must be evaluated back into the same
    /// world the call came from, or the pending-promise map never resolves.
    func testExtensionPageDocumentCompletesAFullRoundTrip() async throws {
        let router = makeRouter()
        let webView = makeWebView(bridgeWorld: ExtensionContentWorld.extensionPage, router: router)
        try await loadProbe(into: webView)

        let result = await poll(webView, .page, "window.__roundTrip", until: "theme=dark")
        XCTAssertEqual(
            result, "theme=dark",
            "browser.storage round trip did not resolve in the popup's world; got '\(result)'")
    }

    // MARK: - The untrusted-page surface

    /// The other half of the design: a content script and the bridge it talks to
    /// live in an isolated world, so a hostile page cannot read, wrap, or replace
    /// either one.
    func testPageScriptCannotSeeTheIsolatedContentScriptBridge() async throws {
        let router = makeRouter()
        let marker = WKUserScript(
            source: "window.__qwaveContentScriptMarker = 'secret';",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: ExtensionContentWorld.isolated
        )
        let webView = makeWebView(
            bridgeWorld: ExtensionContentWorld.isolated,
            router: router,
            contentScripts: [marker]
        )
        try await loadProbe(into: webView)

        // The document's own script ran in the page world and must see nothing.
        let browserType = try await evalString(webView, .page, "window.__typeofBrowser")
        XCTAssertEqual(browserType, "undefined", "page script must not see the extension bridge")
        let handlerType = try await evalString(webView, .page, "window.__typeofHandler")
        XCTAssertEqual(handlerType, "undefined", "page script must not see the qwaveExtension handler")
        let markerType = try await evalString(webView, .page, "window.__typeofMarker")
        XCTAssertEqual(markerType, "undefined", "page script must not see an extension content script")

        // Same web view, isolated world: everything is there.
        let isolatedBrowser = try await evalString(
            webView, ExtensionContentWorld.isolated, "typeof window.browser")
        XCTAssertEqual(isolatedBrowser, "object", "content scripts must still see the bridge")
        let isolatedMarker = try await evalString(
            webView, ExtensionContentWorld.isolated, "window.__qwaveContentScriptMarker")
        XCTAssertEqual(isolatedMarker, "secret")
    }

    /// A content script in the isolated world must still get its replies back.
    func testIsolatedContentScriptCompletesAFullRoundTrip() async throws {
        let router = makeRouter()
        let webView = makeWebView(bridgeWorld: ExtensionContentWorld.isolated, router: router)
        try await loadProbe(into: webView)

        // `evalString` splices into `String(...)`, so this has to stay a single
        // expression: an IIFE, not a statement list.
        let script = """
            (function () {
              window.__isolatedRoundTrip = 'pending';
              window.browser.storage.local.set({ theme: 'dark' })
                .then(function () { return window.browser.storage.local.get('theme'); })
                .then(function (v) { window.__isolatedRoundTrip = 'theme=' + (v && v.theme); })
                .catch(function (e) { window.__isolatedRoundTrip = 'error:' + e; });
              return 'started';
            })()
            """
        let started = try await evalString(webView, ExtensionContentWorld.isolated, script)
        XCTAssertEqual(started, "started")

        let result = await poll(
            webView, ExtensionContentWorld.isolated, "window.__isolatedRoundTrip", until: "theme=dark")
        XCTAssertEqual(
            result, "theme=dark",
            "browser.storage round trip did not resolve in the isolated world; got '\(result)'")
    }

    // MARK: - The two worlds are distinct

    func testTheTwoSurfaceWorldsAreNotTheSameWorld() {
        XCTAssertEqual(ExtensionContentWorld.isolated.name, "QwaveExtensions")
        XCTAssertEqual(ExtensionContentWorld.extensionPage, WKContentWorld.page)
        XCTAssertNotEqual(ExtensionContentWorld.isolated, ExtensionContentWorld.extensionPage)
    }
}
