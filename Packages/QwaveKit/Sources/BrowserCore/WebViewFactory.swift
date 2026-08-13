import WebKit
import Shields
import FeatureFlags
import Persistence

/// The convergence point: everything that shapes a page's environment —
/// container isolation, shields, feature flags, energy settings — flows into
/// the `WKWebViewConfiguration` built here.
@MainActor
public final class WebViewFactory {
    private let containers: ContainerRegistry
    private let shields: ShieldsDirector
    private let featureFlags: FeatureFlagService
    private let settings: SettingsStore

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

    public func makeWebView(for tab: Tab) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = containers.dataStore(for: tab.containerID)

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
