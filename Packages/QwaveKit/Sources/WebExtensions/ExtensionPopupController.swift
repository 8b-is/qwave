import AppKit
import WebKit

/// Renders an extension's action popup in an NSPopover, with the
/// `browser.*` bridge installed.
@MainActor
public final class ExtensionPopupController: NSObject, NSPopoverDelegate {
    public let popover = NSPopover()
    public let router: ExtensionMessageRouter

    private let webView: WKWebView
    private var responder: WebViewBridgeResponder?

    public init(router: ExtensionMessageRouter) {
        self.router = router
        let configuration = WKWebViewConfiguration()
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        configuration.userContentController.add(router, name: BrowserBridgeScript.messageHandlerName)
        let script = WKUserScript(
            source: BrowserBridgeScript.source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
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
    public func showPopup(for ext: WebExtension, relativeTo positioningView: NSView, of positioningRect: NSRect) {
        responder = WebViewBridgeResponder(webView: webView)
        router.responder = responder

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
