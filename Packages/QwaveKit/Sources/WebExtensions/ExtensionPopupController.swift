#if os(macOS)
    import AppKit
    import WebKit

    /// Renders an extension's action popup in an NSPopover, with the
    /// `browser.*` bridge installed.
    @MainActor
    public final class ExtensionPopupController: NSObject, NSPopoverDelegate {
        public let popover = NSPopover()
        public let router: ExtensionMessageRouter

        private let webView: WKWebView

        public init(router: ExtensionMessageRouter) {
            self.router = router
            let configuration = WKWebViewConfiguration()
            self.webView = WKWebView(frame: .zero, configuration: configuration)
            super.init()

            // The popup is the extension's own chrome, loaded off its own bundle —
            // trusted markup, not a page to defend against. Its scripts run in
            // `WKContentWorld.page` like any document's do, so the bridge goes
            // there too; installed into the isolated world it would be invisible to
            // popup.html and every `browser.*` call in it would throw. Web pages
            // keep the isolated world (see `WebExtensionHost.installBridge`), which
            // is where isolation actually defends something.
            configuration.userContentController.add(
                router,
                contentWorld: ExtensionContentWorld.extensionPage,
                name: BrowserBridgeScript.messageHandlerName
            )
            let script = WKUserScript(
                source: BrowserBridgeScript.source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: ExtensionContentWorld.extensionPage
            )
            configuration.userContentController.addUserScript(script)

            popover.contentViewController = makeContentController()
            popover.contentSize = NSSize(width: 360, height: 480)
            popover.behavior = .transient
            popover.delegate = self
        }

        private func makeContentController() -> NSViewController {
            let controller = NSViewController()
            controller.view = webView
            return controller
        }

        /// Shows the popup for an extension anchored to `positioningView`.
        ///
        /// The popup registers no responder with the router: the router replies
        /// into whichever web view a bridge call arrived from, so opening a second
        /// popup can no longer steal the first one's replies.
        public func showPopup(for ext: WebExtension, relativeTo positioningView: NSView, of positioningRect: NSRect) {
            if let popupURL = ext.popupURL {
                webView.loadFileURL(popupURL, allowingReadAccessTo: ext.bundleURL)
            } else {
                let html = """
                    <html><body style="font-family:-apple-system;padding:1rem">
                    <h2>\(ext.manifest.name)</h2><p>No popup declared in manifest.json.</p>
                    </body></html>
                    """
                webView.loadHTMLString(html, baseURL: ext.bundleURL)
            }
            popover.show(relativeTo: positioningRect, of: positioningView, preferredEdge: .minY)
        }

        public func close() {
            popover.performClose(nil)
        }
    }
#endif
