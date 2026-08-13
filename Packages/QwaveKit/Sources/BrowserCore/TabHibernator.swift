import AppKit
import WebKit
import QwaveSupport

/// Performs the actual hibernate/restore mechanics on a tab's web view:
/// snapshot for the placeholder, capture `interactionState` (back/forward
/// stack, scroll position, form state), then tear the web view down —
/// releasing its web-content and GPU processes entirely.
@MainActor
public final class TabHibernator {
    private let factory: WebViewFactory

    public init(factory: WebViewFactory) {
        self.factory = factory
    }

    /// Snapshot + capture + tear down. The web view must be detached from the
    /// view hierarchy by the caller after this returns.
    public func hibernate(_ tab: Tab) async {
        guard let webView = tab.webView else { return }
        let signpostID = QwaveSignposts.energy.makeSignpostID()
        let interval = QwaveSignposts.energy.beginInterval("hibernate", id: signpostID)
        defer { QwaveSignposts.energy.endInterval("hibernate", interval) }

        let snapshot: NSImage? = await withCheckedContinuation { continuation in
            let configuration = WKSnapshotConfiguration()
            configuration.afterScreenUpdates = false
            webView.takeSnapshot(with: configuration) { image, _ in
                continuation.resume(returning: image)
            }
        }

        let record = HibernationRecord(
            url: webView.url ?? tab.url,
            title: webView.title ?? tab.title,
            interactionState: webView.interactionState as? Data,
            snapshot: snapshot
        )

        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        tab.hibernate(with: record)
        QwaveLog.energy.info("Hibernated tab \(tab.id, privacy: .public)")
    }

    /// Rebuild the web view and restore captured state.
    public func restore(_ tab: Tab) -> WKWebView {
        let signpostID = QwaveSignposts.energy.makeSignpostID()
        let interval = QwaveSignposts.energy.beginInterval("wake", id: signpostID)
        let webView = factory.restoreWebView(for: tab)
        QwaveSignposts.energy.endInterval("wake", interval)
        QwaveLog.energy.info("Restored tab \(tab.id, privacy: .public)")
        return webView
    }

    /// Media playback pause/suspend used by the energy tiers for tabs that
    /// stay live.
    public func applyMediaPolicy(_ policy: EnergyPolicy, to tab: Tab, isSelected: Bool) {
        guard let webView = tab.webView, !isSelected else { return }
        if policy.suspendAllBackgroundMedia {
            webView.setAllMediaPlaybackSuspended(true)
        } else {
            webView.setAllMediaPlaybackSuspended(false)
            if policy.pauseBackgroundMedia {
                webView.pauseAllMediaPlayback()
            }
        }
    }
}
