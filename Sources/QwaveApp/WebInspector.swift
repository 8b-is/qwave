import AppKit
import WebKit

/// Opens WebKit's Web Inspector (the same panel as right-click → "Inspect
/// Element") programmatically, so DevTools can be driven from a menu item and
/// keyboard shortcut like Chrome/Safari.
///
/// `WKWebView.isInspectable` (set in WebViewFactory) enables the inspector, but
/// WebKit exposes no *public* API to open it. This uses WebKit's private
/// `_inspector` API, guarded with `responds(to:)` so it silently no-ops if the
/// SPI ever changes — right-click "Inspect Element" remains the fallback. This
/// is acceptable because Qwave ships via Developer ID, not the App Store.
@MainActor
enum WebInspector {
    static func show(for webView: WKWebView) { perform("show", on: webView) }

    static func showConsole(for webView: WKWebView) { perform("showConsole", on: webView) }

    private static func inspector(for webView: WKWebView) -> NSObject? {
        let selector = NSSelectorFromString("_inspector")
        guard webView.responds(to: selector) else { return nil }
        return webView.perform(selector)?.takeUnretainedValue() as? NSObject
    }

    private static func perform(_ selectorName: String, on webView: WKWebView) {
        guard let inspector = inspector(for: webView) else { return }
        let selector = NSSelectorFromString(selectorName)
        guard inspector.responds(to: selector) else { return }
        _ = inspector.perform(selector)
    }
}
