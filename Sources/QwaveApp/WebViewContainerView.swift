import AppKit
import WebKit

/// Hosts the selected tab's web view, swapping subviews on tab switch.
final class WebViewContainerView: NSView {
    private(set) weak var currentWebView: WKWebView?

    func show(_ webView: WKWebView) {
        guard currentWebView !== webView else { return }
        currentWebView?.removeFromSuperview()
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        currentWebView = webView
    }

    override var acceptsFirstResponder: Bool { true }
}
