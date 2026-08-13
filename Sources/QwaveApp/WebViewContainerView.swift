import AppKit
import WebKit

/// Hosts the selected tab's web view, swapping subviews on tab switch.
final class WebViewContainerView: NSView {
    private(set) weak var currentWebView: WKWebView?
    var onDropFile: ((URL) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard
            let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
            let url = urls.first
        else { return false }
        onDropFile?(url)
        return true
    }

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
