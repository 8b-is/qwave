// QwaveIOSApp.swift — the iPhone entry point.
//
// The same sovereign browser core as the macOS app (WebKit + QwaveKit:
// shields, container registry, feature flags, settings), in a SwiftUI shell.
// Minimum supported device: iPhone 13 (iOS 15). There is deliberately no
// AppKit here — this file and its siblings are the iOS lane, and the
// platform gates in QwaveKit are what make the shared core build on both.

import SwiftUI
import WebKit
import BrowserCore
import Shields
import FeatureFlags
import Persistence

/// BrowserCore's tab type, aliased: `Tab` collides with SwiftUI's `Tab`.
typealias BrowserTab = BrowserCore.Tab

@main
struct QwaveIOSApp: App {
    @StateObject private var model = BrowserViewModel()

    var body: some Scene {
        WindowGroup {
            BrowserView(model: model)
                .onOpenURL { url in
                    model.open(url)
                }
        }
    }
}

/// The iPhone browser shell: omnibox + tab strip + the WebKit view, with the
/// QwaveKit shields applied by the shared WebViewFactory.
@MainActor
final class BrowserViewModel: ObservableObject {
    @Published var tabs: [BrowserTab] = [BrowserTab(pendingURL: URL(string: "https://vaked.dev"))]
    @Published var activeTabID: UUID
    @Published var address: String = ""
    @Published var loading = false
    @Published var canGoBack = false
    @Published var canGoForward = false

    let factory: WebViewFactory

    init() {
        let firstTab = BrowserTab(pendingURL: URL(string: "https://vaked.dev"))
        let containers = ContainerRegistry(directory: QwaveDirectories.iosContainers)
        let compiler = RuleListCompiler()
        let shieldDirector = ShieldsDirector(
            compiler: compiler,
            policy: ShieldsPolicy(directory: QwaveDirectories.iosPolicy)
        )
        let featureFlags = FeatureFlagService()
        let settings = SettingsStore()
        factory = WebViewFactory(
            containers: containers,
            shields: shieldDirector,
            featureFlags: featureFlags,
            settings: settings
        )
        tabs = [firstTab]
        activeTabID = firstTab.id
        address = firstTab.pendingURL?.absoluteString ?? ""
    }

    func open(_ url: URL) {
        tabs.append(BrowserTab(pendingURL: url))
        activeTabID = tabs[tabs.count - 1].id
        address = url.absoluteString
    }

    func newTab() {
        tabs.append(BrowserTab(pendingURL: nil))
        activeTabID = tabs[tabs.count - 1].id
        address = ""
    }

    func closeTab(_ id: UUID) {
        guard tabs.count > 1 else { return }
        tabs.removeAll { $0.id == id }
        if activeTabID == id {
            activeTabID = tabs.last?.id ?? tabs[0].id
        }
    }

    func webView(for tab: BrowserTab) -> WKWebView {
        if let existing = tab.webView { return existing }
        return factory.makeWebView(for: tab)
    }

    /// Navigate the address bar text. Falls back to a search when it is not
    /// a URL — the same what-you-typed logic the desktop omnibox uses.
    func navigate(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let active = tabs.first(where: { $0.id == activeTabID }) else { return }
        let url: URL
        if let parsed = URL(string: trimmed), parsed.scheme != nil {
            url = parsed
        } else if trimmed.contains(".") && !trimmed.contains(" ") {
            url = URL(string: "https://\(trimmed)") ?? URL(string: "https://duckduckgo.com/?q=\(trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")!
        } else {
            url = URL(string: "https://duckduckgo.com/?q=\(trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")!
        }
        let webView = webView(for: active)
        active.pendingURL = url
        webView.load(URLRequest(url: url))
        address = url.absoluteString
    }
}

/// iOS-only directory helpers — the macOS app has its own.
enum QwaveDirectories {
    static var iosContainers: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("containers", isDirectory: true)
    }

    static var iosPolicy: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("shields", isDirectory: true)
    }
}
