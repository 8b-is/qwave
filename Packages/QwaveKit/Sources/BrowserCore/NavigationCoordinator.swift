import AppKit
import WebKit
import Shields
import Persistence
import QwaveSupport

/// Per-tab `WKNavigationDelegate`/`WKUIDelegate` hub. Routes policy decisions
/// through shields (HTTPS-first, per-site JS), hands downloads to the
/// download manager, records history, and mirrors web-view state onto the Tab
/// model via KVO.
@MainActor
public final class NavigationCoordinator: NSObject {
    public weak var tab: Tab?

    private let shields: ShieldsDirector
    private let httpsUpgrader: HTTPSFirstUpgrader
    private let history: HistoryStore?
    private let downloads: DownloadManager

    /// (url, activate) — open a link in a new tab in the same container.
    public var onOpenNewTab: ((URL?, Bool) -> Void)?
    /// Any observable state changed (title, url, progress, loading).
    public var onStateChange: (() -> Void)?

    private var observations: [NSKeyValueObservation] = []

    public init(
        tab: Tab,
        shields: ShieldsDirector,
        httpsUpgrader: HTTPSFirstUpgrader,
        history: HistoryStore?,
        downloads: DownloadManager
    ) {
        self.tab = tab
        self.shields = shields
        self.httpsUpgrader = httpsUpgrader
        self.history = history
        self.downloads = downloads
        super.init()
    }

    /// Wire this coordinator to the tab's freshly built web view.
    public func attach(to webView: WKWebView) {
        webView.navigationDelegate = self
        webView.uiDelegate = self

        observations = [
            webView.observe(\.title) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    guard let self, let tab = self.tab else { return }
                    tab.title = webView.title ?? ""
                    if let url = webView.url, let title = webView.title, !title.isEmpty, !tab.isEphemeral {
                        try? self.history?.updateTitle(title, for: url, containerID: tab.containerID)
                    }
                    self.onStateChange?()
                }
            },
            webView.observe(\.url) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    guard let self, let tab = self.tab else { return }
                    tab.url = webView.url
                    self.onStateChange?()
                }
            },
            webView.observe(\.estimatedProgress) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    guard let self, let tab = self.tab else { return }
                    tab.estimatedProgress = webView.estimatedProgress
                    self.onStateChange?()
                }
            },
            webView.observe(\.isLoading) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    guard let self, let tab = self.tab else { return }
                    tab.isLoading = webView.isLoading
                    self.onStateChange?()
                }
            },
        ]
    }

    public func detach() {
        observations.forEach { $0.invalidate() }
        observations = []
    }
}

// MARK: - WKNavigationDelegate

extension NavigationCoordinator: WKNavigationDelegate {
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        let url = navigationAction.request.url
        let host = url?.host

        // Cmd-click → background tab in the same container.
        if isMainFrame,
           navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command),
           let url {
            decisionHandler(.cancel, preferences)
            onOpenNewTab?(url, navigationAction.modifierFlags.contains(.shift))
            return
        }

        let policy = shields.policy.resolvedPolicy(forHost: host)

        // HTTPS-first upgrade for main-frame http navigations.
        if let url, isMainFrame {
            let decision = httpsUpgrader.decision(
                for: url,
                isMainFrame: isMainFrame,
                policyAllowsUpgrade: policy.httpsFirst
            )
            if case .upgrade(let upgraded) = decision {
                decisionHandler(.cancel, preferences)
                webView.load(URLRequest(url: upgraded))
                return
            }
        }

        // Reconcile rule lists for the destination site before content loads.
        if isMainFrame {
            shields.applyLists(to: webView.configuration.userContentController, forHost: host)
        }

        preferences.allowsContentJavaScript = policy.jsEnabled
        decisionHandler(.allow, preferences)
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        downloads.track(download)
    }

    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        downloads.track(download)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let tab, let url = webView.url else { return }
        httpsUpgrader.noteSuccessfulNavigation(to: url)

        if !tab.isEphemeral, let scheme = url.scheme, scheme == "http" || scheme == "https" {
            try? history?.recordVisit(url: url, title: webView.title, containerID: tab.containerID)
        }
        onStateChange?()
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleFailure(webView: webView, error: error)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleFailure(webView: webView, error: error)
    }

    private func handleFailure(webView: WKWebView, error: Error) {
        let nsError = error as NSError

        // Benign: user navigated away / we cancelled for an upgrade.
        if nsError.code == NSURLErrorCancelled || nsError.domain == "WebKitErrorDomain" && nsError.code == 102 {
            return
        }

        // HTTPS-first fallback: retry the original http URL once.
        let failingURL = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url
        if let fallback = httpsUpgrader.fallbackURL(afterFailureOf: failingURL, errorCode: nsError.code) {
            QwaveLog.shields.info("HTTPS-first fallback to \(fallback.host ?? "?", privacy: .public)")
            webView.load(URLRequest(url: fallback))
            return
        }

        showErrorPage(in: webView, error: nsError, url: failingURL)
        onStateChange?()
    }

    private func showErrorPage(in webView: WKWebView, error: NSError, url: URL?) {
        let host = url?.host ?? ""
        let message = error.localizedDescription
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <style>
          body { font-family: -apple-system, sans-serif; display: flex; align-items: center;
                 justify-content: center; height: 90vh; color: #444; }
          @media (prefers-color-scheme: dark) { body { background: #1e1e1e; color: #bbb; } }
          .card { max-width: 26em; text-align: center; }
          h1 { font-size: 1.2em; }
        </style></head><body><div class="card">
        <h1>Can’t open \(host.isEmpty ? "this page" : host)</h1>
        <p>\(message)</p>
        </div></body></html>
        """
        webView.loadHTMLString(html, baseURL: url)
    }
}

// MARK: - WKUIDelegate

extension NavigationCoordinator: WKUIDelegate {
    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // Popups become tabs in the same container. Returning nil declines
        // the window; we load the URL ourselves.
        onOpenNewTab?(navigationAction.request.url, true)
        return nil
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completionHandler()
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = prompt
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        let response = alert.runModal()
        completionHandler(response == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    public func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.begin { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    public func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.prompt)
    }

    public func webViewDidClose(_ webView: WKWebView) {
        // Page called window.close(): surface as state change; the window
        // controller decides whether to close the tab.
        onStateChange?()
    }
}
