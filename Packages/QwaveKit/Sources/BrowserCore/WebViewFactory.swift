import WebKit
import Shields
import FeatureFlags
import Persistence
import QwaveSupport

/// The convergence point: everything that shapes a page's environment —
/// container isolation, shields, feature flags, energy settings — flows into
/// the `WKWebViewConfiguration` built here.
@MainActor
public final class WebViewFactory {
    private let containers: ContainerRegistry
    private let shields: ShieldsDirector
    private let featureFlags: FeatureFlagService
    private let settings: SettingsStore
    /// Shared process pool for warm-process pre-warming. Non-nil when
    /// `warmProcessCount > 0` — held so WebKit keeps a WebContent process
    /// alive for faster wake-to-interactive. Nil at .conserve and .critical
    /// tiers so the 45.7 MB/tab reclamation floor is not silently eroded.
    private var warmPool: WKProcessPool?

    public init(
        containers: ContainerRegistry,
        shields: ShieldsDirector,
        featureFlags: FeatureFlagService,
        settings: SettingsStore
    ) {
        self.containers = containers
        self.shields = shields
        self.featureFlags = featureFlags
        self.settings = settings
    }

    /// Sets the number of spare WebContent processes to keep warm.
    /// Currently only 0 or 1 are supported; values > 1 clamp to 1.
    public func setWarmProcessCount(_ count: Int) {
        if count > 0, warmPool == nil {
            warmPool = WKProcessPool()
        } else if count == 0, warmPool != nil {
            warmPool = nil
        }
    }

    public func makeWebView(for tab: Tab) -> WKWebView {
        // P0 instrumentation: the interval spans configuration build + rule-list
        // attach + WebContent process spin-up. At iteration 0 the warm pool is
        // cold, so this interval is where the +57% cold-start gap lands. See docs/PERF.md.
        let signpostID = QwaveSignposts.coldstart.makeSignpostID()
        let interval = QwaveSignposts.coldstart.beginInterval("makeWebView", id: signpostID)
        defer { QwaveSignposts.coldstart.endInterval("makeWebView", interval) }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = containers.dataStore(for: tab.containerID)
        if let warmPool {
            configuration.processPool = warmPool
        }

        // Present as Safari for site compatibility (the WebKit engine really
        // is Safari's; only the app token differs).
        configuration.applicationNameForUserAgent = "Version/17.4 Safari/605.1.15"

        // WebKit's own known-hosts HTTPS upgrade, on top of our HTTPS-first.
        configuration.upgradeKnownHostsToHTTPS = true
        configuration.suppressesIncrementalRendering = false
        configuration.allowsAirPlayForMediaPlayback = true
        // One handler instance per configuration — WebKit forbids reuse.
        configuration.setURLSchemeHandler(QwaveSchemeHandler(), forURLScheme: QwaveSchemeHandler.scheme)

        let preferences = configuration.preferences
        preferences.isElementFullscreenEnabled = true
        preferences.isFraudulentWebsiteWarningEnabled = true
        preferences.tabFocusesLinks = false

        // User's experimental WebKit feature overrides (Stage: bleeding edge).
        featureFlags.apply(to: preferences)

        // Content blocking + HTTPS upgrade rule lists per current policy.
        shields.installDefaultLists(on: configuration.userContentController)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsMagnification = true
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true
        webView.translatesAutoresizingMaskIntoConstraints = false

        tab.attach(webView: webView)
        return webView
    }

    /// Rebuilds a web view for a hibernated tab and restores its interaction
    /// state (back/forward stack, scroll position, form data).
    public func restoreWebView(for tab: Tab) -> WKWebView {
        let record = tab.hibernationRecord
        let webView = makeWebView(for: tab)
        if let state = record?.interactionState {
            webView.interactionState = state
        } else if let url = record?.url ?? tab.url {
            webView.load(URLRequest(url: url))
        }
        return webView
    }
}
