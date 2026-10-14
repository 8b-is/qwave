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
    private let permissions: WebPermissionStore
    private let ephemeralPermissions: WebPermissionStore
    private weak var attachedWebView: WKWebView?

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
    // Test transports may replace the wire, but cannot inject shared storage.
    var markdownProtocolClasses: [AnyClass]?
    private struct MarkdownFetch {
        let id: UUID
        let tabID: UUID
        let task: Task<(Data, URLResponse), Error>
    }
    private var markdownFetch: MarkdownFetch?
    private var isDetached = false
    private struct LocalDocumentLoad {
        let token: String
        let url: URL
        let webView: ObjectIdentifier
    }
    private var localDocumentLoad: LocalDocumentLoad?
    private static let localDocumentHeader = "X-Qwave-Local-Document"

    public init(
        tab: Tab,
        shields: ShieldsDirector,
        httpsUpgrader: HTTPSFirstUpgrader,
        history: HistoryStore?,
        downloads: DownloadManager,
        permissions: WebPermissionStore = .shared
    ) {
        self.tab = tab
        self.shields = shields
        self.httpsUpgrader = httpsUpgrader
        self.history = history
        self.downloads = downloads
        self.permissions = permissions
        ephemeralPermissions = WebPermissionStore(invalidationSource: permissions, containerID: tab.containerID)
        super.init()
    }

    /// Wire this coordinator to the tab's freshly built web view.
    public func attach(to webView: WKWebView) {
        cancelMarkdownFetch()
        localDocumentLoad = nil
        isDetached = false
        if attachedWebView !== webView { ephemeralPermissions.reset() }
        attachedWebView = webView
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
        isDetached = true
        cancelMarkdownFetch()
        localDocumentLoad = nil
        attachedWebView = nil
        ephemeralPermissions.reset()
        observations.forEach { $0.invalidate() }
        observations = []
        tab?.webView?.configuration.userContentController.removeScriptMessageHandler(forName: "qwave")
    }

    private func cancelMarkdownFetch() {
        markdownFetch?.task.cancel()
        markdownFetch = nil
    }

    /// Follow the actual storage lifetime, including custom nonpersistent
    /// profiles. The shared burner profile ID is not a consent boundary.
    func permissionStore(for webView: WKWebView) -> WebPermissionStore? {
        guard let tab, tab.webView === webView, attachedWebView === webView else { return nil }
        return tab.isEphemeral || !webView.configuration.websiteDataStore.isPersistent
            ? ephemeralPermissions : permissions
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

        // Only our one pending simulated file load may skip file resolution.
        // Consume its nonce on the next main-frame intent, including a
        // mismatching one; reloads/back/forward and ordinary file requests
        // must resolve and sanitise the source again.
        var isGeneratedLocalDocument = false
        if navigationAction.targetFrame?.isMainFrame == true {
            if let pending = localDocumentLoad {
                isGeneratedLocalDocument =
                    !isDetached && pending.url == url
                    && pending.webView == ObjectIdentifier(webView) && tab?.webView === webView
                    && navigationAction.navigationType == .other
                    && navigationAction.request.value(forHTTPHeaderField: Self.localDocumentHeader) == pending.token
            }
            localDocumentLoad = nil
        }

        // A new main-frame intent supersedes the reader's re-fetch, even if
        // the next navigation is later cancelled or redirected by policy.
        // Popups and subframes do not replace this tab's document.
        if navigationAction.targetFrame?.isMainFrame == true, tab?.webView === webView {
            cancelMarkdownFetch()
        }

        if isMainFrame, let url, url.scheme == QwaveSchemeHandler.scheme {
            preferences.allowsContentJavaScript = true
            decisionHandler(.allow, preferences)
            return
        }

        if isMainFrame, let url, url.isFileURL {
            preferences.allowsContentJavaScript = true
            if isGeneratedLocalDocument {
                decisionHandler(.allow, preferences)
                return
            }
            switch LocalDocumentResolver.resolve(url) {
            case .file:
                decisionHandler(.allow, preferences)
            case .htmlIndex(let file, let root):
                decisionHandler(.cancel, preferences)
                webView.loadFileURL(file, allowingReadAccessTo: root)
            case .markdown(let source, let file):
                decisionHandler(.cancel, preferences)
                // A downloaded `.md` rendered at its own file:// URL: sanitise.
                presentMarkdown(source, at: file, trust: .compilerOutputOnly, in: webView)
            case .listing(let markdown, let directory):
                decisionHandler(.cancel, preferences)
                // Same origin, and the markdown here is *synthesised from file
                // names* (`LocalDocumentResolver.directoryListingMarkdown`), so
                // the untrusted input is the directory's contents.
                presentMarkdown(markdown, at: directory, trust: .compilerOutputOnly, in: webView)
            case .missing:
                decisionHandler(.cancel, preferences)
                loadGeneratedHTML(
                    InternalPages.httpErrorHTML(status: 404, host: url.lastPathComponent),
                    at: url, in: webView
                )
            }
            return
        }

        if url?.scheme == "qwave", url?.host == "arcade" {
            preferences.allowsContentJavaScript = true
            decisionHandler(.allow, preferences)
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

        if let request = ReadingLanguageRequest.adapted(
            navigationAction.request, mainFrame: isMainFrame, currentURL: webView.url)
        {
            decisionHandler(.cancel, preferences)
            webView.load(request)
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
                // Allocate the identity synchronously: a later navigation can
                // invalidate this request before the presentation task starts.
                if let fetch = beginMarkdownFetch(url, in: webView) {
                    Task { await self.presentMarkdownResponse(fetch, requestedURL: url, in: webView) }
                }
                return
            }
            if let http = navigationResponse.response as? HTTPURLResponse,
                QwaveSchemeHandler.shouldShowWaveError(status: QwaveHTTPStatus(rawValue: http.statusCode))
            {
                decisionHandler(.cancel)
                let host = http.url.flatMap(CanonicalHost.host(of:)) ?? http.url?.host ?? ""
                loadGeneratedHTML(
                    InternalPages.httpErrorHTML(status: http.statusCode, host: host),
                    at: http.url, in: webView
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
        if tab?.webView === webView {
            cancelMarkdownFetch()
            localDocumentLoad = nil
        }
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
        if let arcade = OfflineArcade.pageURL(error: nsError, failingURL: failingURL) {
            webView.load(URLRequest(url: arcade))
            onStateChange?()
            return
        }
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
        loadGeneratedHTML(html, at: url, in: webView)
    }

    /// - Parameter trust: which origin the compiled page will end up in.
    ///   The HTML load below adopts `url`'s origin, so this is
    ///   the caller's answer to "would script in this document be running as
    ///   the document's own site, or as the user's `file://` origin?" — see
    ///   `MarkdownTrust` and issue #131.
    private func presentMarkdown(
        _ source: String, at url: URL, trust: MarkdownTrust, in webView: WKWebView
    ) {
        let title = url.lastPathComponent
        let body = MarkdownCompiler.compile(source, trust: trust)
        let html = InternalPages.markdownHTML(
            title: title, bodyHTML: body, source: source, allowRemember: tab?.isEphemeral != true)
        loadGeneratedHTML(html, at: url, in: webView)
        tab?.url = url
        tab?.title = title
        onStateChange?()
    }

    private func loadGeneratedHTML(_ html: String, at url: URL?, in webView: WKWebView) {
        localDocumentLoad = nil
        guard let url else {
            webView.loadHTMLString(html, baseURL: nil)
            return
        }
        let scheme = url.scheme?.lowercased()
        guard url.isFileURL || scheme == "http" || scheme == "https" else {
            webView.loadHTMLString(html, baseURL: url)
            return
        }
        // loadHTMLString synthesizes a headerless request. The normal reading
        // language policy would replay it over the network, losing our HTML
        // and fetching the failed URL or Markdown again. A simulated response
        // retains the request's language policy without sending it again.
        var request = URLRequest(url: url)
        if url.isFileURL {
            let token = UUID().uuidString
            localDocumentLoad = LocalDocumentLoad(token: token, url: url, webView: ObjectIdentifier(webView))
            // This request is simulated and never sent to the URL. The nonce
            // distinguishes compiled/sanitised HTML from a fresh file load,
            // which otherwise recursively resolves the same Markdown again.
            request.setValue(token, forHTTPHeaderField: Self.localDocumentHeader)
        }
        let adapted = ReadingLanguageRequest.adapted(request, mainFrame: true) ?? request
        webView.loadSimulatedRequest(adapted, responseHTML: html)
    }

    /// Re-fetches the markdown document WebKit just started loading (we
    /// cancelled that navigation in `decidePolicyFor navigationResponse`) and
    /// renders it in the reader.
    ///
    /// Each request uses a fresh ephemeral session seeded from this web view's
    /// cookie store. No shared cache or credentials, and no response-cookie
    /// writeback: the original WebKit navigation owns browser cookie updates.
    /// The explicit page-driven marker exempts this navigated document from
    /// EgressGuard, which is installed in the disposable session.
    ///
    /// Internal rather than private so `EgressGuardTests` can drive the real
    /// fetch and its storage configuration instead of restating them.
    func fetchAndPresentMarkdown(_ url: URL, in webView: WKWebView) async {
        guard let fetch = beginMarkdownFetch(url, in: webView) else { return }
        await presentMarkdownResponse(fetch, requestedURL: url, in: webView)
    }

    private func beginMarkdownFetch(_ url: URL, in webView: WKWebView) -> MarkdownFetch? {
        guard !isDetached, let tab, tab.webView === webView else { return nil }
        cancelMarkdownFetch()
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        let protocols = markdownProtocolClasses
        let fetch = MarkdownFetch(
            id: UUID(), tabID: tab.id,
            task: Task {
                let cookies = await cookieStore.allCookies()
                try Task.checkCancellation()
                return try await MarkdownDocumentLoader.fetch(url, cookies: cookies, protocols: protocols)
            })
        markdownFetch = fetch
        return fetch
    }

    private func isCurrentMarkdownFetch(_ fetch: MarkdownFetch, in webView: WKWebView) -> Bool {
        !Task.isCancelled && !isDetached && markdownFetch?.id == fetch.id
            && tab?.id == fetch.tabID && tab?.webView === webView
    }

    private func presentMarkdownResponse(_ fetch: MarkdownFetch, requestedURL url: URL, in webView: WKWebView) async {
        defer {
            // An older completion must not clear the newer request's handle.
            if markdownFetch?.id == fetch.id { markdownFetch = nil }
        }
        guard isCurrentMarkdownFetch(fetch, in: webView) else {
            fetch.task.cancel()
            return
        }
        do {
            let task = fetch.task
            let (data, response) = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard isCurrentMarkdownFetch(fetch, in: webView) else { return }
            guard let http = response as? HTTPURLResponse,
                let responseURL = http.url,
                let scheme = responseURL.scheme?.lowercased(), scheme == "http" || scheme == "https",
                CanonicalHost.host(of: responseURL) != nil
            else { throw URLError(.badServerResponse) }

            guard (200..<300).contains(http.statusCode) else {
                // An error body is not the Markdown document the user requested.
                loadGeneratedHTML(
                    InternalPages.httpErrorHTML(status: http.statusCode, host: responseURL.host ?? ""),
                    at: responseURL, in: webView
                )
                tab?.url = responseURL
                tab?.title = String(http.statusCode)
                onStateChange?()
                return
            }
            let source = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            // URLSession follows redirects. Raw HTML must run as the FINAL
            // response's origin, never as the site that redirected to it.
            // Local files use the separate compiler-only path above; a remote
            // response cannot opt into a file or internal-page origin here.
            presentMarkdown(
                source, at: responseURL, trust: .rawHTMLAllowed, in: webView)
        } catch {
            guard isCurrentMarkdownFetch(fetch, in: webView),
                !(error is CancellationError), (error as NSError).code != NSURLErrorCancelled
            else { return }
            loadGeneratedHTML(
                InternalPages.connectionLostHTML(
                    host: url.host ?? url.lastPathComponent, message: error.localizedDescription),
                at: url, in: webView
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
        guard let store = permissionStore(for: webView), let tab else {
            decisionHandler(.deny); return
        }
        WebPermissionArbiter.decideMediaCapture(
            origin: WebPermissionOrigin(origin),
            type: type,
            containerID: tab.containerID,
            store: store
        ) { [weak self, weak webView] decision in
            guard let self, let webView, self.permissionStore(for: webView) === store else {
                decisionHandler(.deny); return
            }
            decisionHandler(decision)
        }
    }

    public func webView(
        _ webView: WKWebView,
        requestGeolocationPermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        guard let store = permissionStore(for: webView), let tab else {
            decisionHandler(.deny); return
        }
        WebPermissionArbiter.decideGeolocation(
            origin: WebPermissionOrigin(origin),
            containerID: tab.containerID,
            store: store
        ) { [weak self, weak webView] decision in
            guard let self, let webView, self.permissionStore(for: webView) === store else {
                decisionHandler(.deny); return
            }
            decisionHandler(decision)
        }
    }

    public func webViewDidClose(_ webView: WKWebView) {
        // Page called window.close(): surface as state change; the window
        // controller decides whether to close the tab.
        onStateChange?()
    }
}
