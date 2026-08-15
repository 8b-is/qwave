#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import WebKit
import Shields
import Persistence
import QwaveSupport
import URLIdentity

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
    /// The page's declared (or default /favicon.ico) icon URL, once known.
    public var onFaviconURL: ((URL) -> Void)?
    /// Start-page submit / markdown remember — handled by the app shell.
    public var onInternalAction: ((QwaveInternalAction) -> Void)?
    /// Main-frame http(s) finished — Remember Everything hooks here.
    public var onMainFrameFinished: ((WKWebView, Tab) -> Void)?

    private var observations: [NSKeyValueObservation] = []
    private let session: URLSession

    public init(
        tab: Tab,
        shields: ShieldsDirector,
        httpsUpgrader: HTTPSFirstUpgrader,
        history: HistoryStore?,
        downloads: DownloadManager,
        session: URLSession = .shared
    ) {
        self.tab = tab
        self.shields = shields
        self.httpsUpgrader = httpsUpgrader
        self.history = history
        self.downloads = downloads
        self.session = session
        super.init()
    }

    /// Wire this coordinator to the tab's freshly built web view.
    public func attach(to webView: WKWebView) {
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "qwave")
        webView.configuration.userContentController.add(self, name: "qwave")

        observations = [
            webView.observe(\.title) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    guard let self, let tab = self.tab else { return }
                    tab.title = webView.title ?? ""
                    if let url = webView.url, let title = webView.title, !title.isEmpty, !tab.isEphemeral {
                        let history = self.history
                        let containerID = tab.containerID
                        Task(priority: .utility) { @MainActor in
                            try? await history?.updateTitle(title, for: url, containerID: containerID)
                        }
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
        tab?.webView?.configuration.userContentController.removeScriptMessageHandler(forName: "qwave")
    }
}

// MARK: - WKNavigationDelegate

extension NavigationCoordinator: WKNavigationDelegate {
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        let url = navigationAction.request.url
        // Policy identity must be the host WebKit will load, not Foundation's
        // reading of it (IDN/percent/authority divergences are a bypass).
        let host = url.flatMap(CanonicalHost.host(of:))

        // Cmd-click → background tab in the same container. Pointer+keyboard
        // interaction; the iOS UI layer (Phase 1) uses long-press instead, and
        // WKNavigationAction.modifierFlags is iOS 18.4+ regardless.
#if os(macOS)
        if isMainFrame,
            navigationAction.navigationType == .linkActivated,
            navigationAction.modifierFlags.contains(.command),
            let url
        {
            decisionHandler(.cancel, preferences)
            onOpenNewTab?(url, navigationAction.modifierFlags.contains(.shift))
            return
        }
#endif

        if isMainFrame, let url, url.scheme == QwaveSchemeHandler.scheme {
            preferences.allowsContentJavaScript = true
            decisionHandler(.allow, preferences)
            return
        }

        if isMainFrame, let url, url.isFileURL {
            preferences.allowsContentJavaScript = true
            switch LocalDocumentResolver.resolve(url) {
            case .file:
                decisionHandler(.allow, preferences)
            case .htmlIndex(let file, let root):
                decisionHandler(.cancel, preferences)
                webView.loadFileURL(file, allowingReadAccessTo: root)
            case .markdown(let source, let file):
                decisionHandler(.cancel, preferences)
                presentMarkdown(source, at: file, in: webView)
            case .listing(let markdown, let directory):
                decisionHandler(.cancel, preferences)
                presentMarkdown(markdown, at: directory, in: webView)
            case .missing:
                decisionHandler(.cancel, preferences)
                webView.loadHTMLString(
                    InternalPages.httpErrorHTML(status: 404, host: url.lastPathComponent),
                    baseURL: url
                )
            }
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

        preferences.allowsContentJavaScript = policy.jsEnabled

        // Subframes don't reconcile shields (the config-wide lists are already
        // attached to the web view) — allow immediately.
        guard isMainFrame else {
            decisionHandler(.allow, preferences)
            return
        }

        // Reconcile rule lists for the destination site, THEN allow the load.
        // On a cold launch this waits for the first rule-list compile, so a
        // network page never loads with shields on but no lists attached — the
        // launch-gate guarantee. Steady state (already prepared) is synchronous.
        let controller = webView.configuration.userContentController
        shields.applyListsThen(to: controller, forHost: host) {
            decisionHandler(.allow, preferences)
        }
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        if navigationResponse.isForMainFrame {
            let mime = navigationResponse.response.mimeType
            let url = navigationResponse.response.url
            if let url, LocalDocumentResolver.isMarkdownURL(url) || LocalDocumentResolver.isMarkdownMIME(mime) {
                decisionHandler(.cancel)
                Task { await self.fetchAndPresentMarkdown(url, in: webView) }
                return
            }
            if let http = navigationResponse.response as? HTTPURLResponse,
                QwaveSchemeHandler.shouldShowWaveError(status: QwaveHTTPStatus(rawValue: http.statusCode))
            {
                decisionHandler(.cancel)
                let host = http.url.flatMap(CanonicalHost.host(of:)) ?? http.url?.host ?? ""
                webView.loadHTMLString(
                    InternalPages.httpErrorHTML(status: http.statusCode, host: host),
                    baseURL: http.url
                )
                return
            }
        }
        if !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload)
    {
        downloads.track(download)
    }

    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        downloads.track(download)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let tab, let url = webView.url else { return }
        httpsUpgrader.noteSuccessfulNavigation(to: url)

        if !tab.isEphemeral, let scheme = url.scheme, scheme == "http" || scheme == "https" {
            let history = history
            let title = webView.title
            let containerID = tab.containerID
            Task(priority: .utility) { @MainActor in
                try? await history?.recordVisit(url: url, title: title, containerID: containerID)
            }
        }
        if let scheme = url.scheme, scheme == "http" || scheme == "https" {
            extractFaviconURL(from: webView)
            onMainFrameFinished?(webView, tab)
        }
        onStateChange?()
    }

    /// `<link rel~=icon>` if the page declares one, /favicon.ico otherwise.
    private func extractFaviconURL(from webView: WKWebView) {
        let script = """
            (function() {
              const links = document.querySelectorAll("link[rel~='icon'], link[rel='shortcut icon']");
              for (const l of links) { if (l.href) { return l.href; } }
              return new URL('/favicon.ico', location.origin).href;
            })()
            """
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            guard let string = result as? String,
                let iconURL = URL(string: string),
                iconURL.scheme == "http" || iconURL.scheme == "https"
            else { return }
            self?.onFaviconURL?(iconURL)
        }
    }

    /// The WebContent process crashed (or was jettisoned under memory
    /// pressure), leaving a blank view. Restore from `interactionState` when
    /// WebKit still holds it (brings back history + scroll), otherwise reload
    /// the current back/forward item — never leave the user staring at a blank
    /// tab.
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        QwaveLog.browser.warning("WebContent process terminated; restoring tab")
        if let state = webView.interactionState as? Data {
            webView.interactionState = state
        } else if webView.url != nil || webView.backForwardList.currentItem != nil {
            webView.reload()
        } else if let url = tab?.url ?? tab?.pendingURL {
            webView.load(URLRequest(url: url))
        }
        onStateChange?()
    }

    public func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
    ) {
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
        let host = url.flatMap(CanonicalHost.host(of:)) ?? url?.host ?? ""
        let html = InternalPages.connectionLostHTML(host: host, message: error.localizedDescription)
        webView.loadHTMLString(html, baseURL: url)
    }

    private func presentMarkdown(_ source: String, at url: URL, in webView: WKWebView) {
        let title = url.lastPathComponent
        let body = MarkdownCompiler.compile(source)
        let html = InternalPages.markdownHTML(
            title: title, bodyHTML: body, source: source, allowRemember: tab?.isEphemeral != true)
        webView.loadHTMLString(html, baseURL: url)
        tab?.url = url
        tab?.title = title
        onStateChange?()
    }

    private func fetchAndPresentMarkdown(_ url: URL, in webView: WKWebView) async {
        do {
            let (data, _) = try await session.data(from: url)
            let source = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            presentMarkdown(source, at: url, in: webView)
        } catch {
            webView.loadHTMLString(
                InternalPages.connectionLostHTML(
                    host: url.host ?? url.lastPathComponent, message: error.localizedDescription),
                baseURL: url
            )
        }
    }
}

extension NavigationCoordinator: WKScriptMessageHandler {
    public func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        guard message.name == "qwave", let body = message.body as? [String: Any],
            let type = body["type"] as? String
        else { return }
        switch type {
        case "submit":
            if let query = body["query"] as? String {
                onInternalAction?(.submit(query))
            }
        case "remember":
            let scope = body["scope"] as? String ?? "page"
            let text = body["text"] as? String ?? ""
            onInternalAction?(.remember(scope: scope, text: text))
        case "summarize":
            if let range = body["range"] as? String {
                onInternalAction?(.summarize(range))
            }
        default:
            break
        }
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

    // JS dialog + file-open panels use AppKit modals; the iOS UI layer
    // (Phase 1) will present these from a view controller.
#if os(macOS)
    public func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable () -> Void
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
        completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
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
        completionHandler: @escaping @MainActor @Sendable (String?) -> Void
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
        completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.begin { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }
#endif

    public func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        WebPermissionArbiter.decideMediaCapture(
            host: origin.host,
            type: type,
            containerID: tab?.containerID,
            completion: decisionHandler)
    }

    public func webView(
        _ webView: WKWebView,
        requestGeolocationPermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        WebPermissionArbiter.decideGeolocation(
            host: origin.host,
            containerID: tab?.containerID,
            completion: decisionHandler)
    }

    public func webViewDidClose(_ webView: WKWebView) {
        // Page called window.close(): surface as state change; the window
        // controller decides whether to close the tab.
        onStateChange?()
    }
}
