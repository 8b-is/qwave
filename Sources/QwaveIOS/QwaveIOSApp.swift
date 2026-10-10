// QwaveIOSApp.swift — the iPhone entry point.
//
// The same sovereign browser core as the macOS app (WebKit + QwaveKit:
// shields, containers, feature flags, settings, AND the Rust core — the
// SovereignCore facade speaks the same mem8 / Phoenix / egress / telemetry
// ABI the desktop app links). Minimum supported device: iPhone 13 (iOS 15).
// There is deliberately no AppKit here.

import SwiftUI
import WebKit
import Combine
import BrowserCore
import URLIdentity
import Shields
import FeatureFlags
import Persistence
import SovereignCore
import MemoryWave
import QwaveSupport

/// BrowserCore's tab type, aliased: `Tab` collides with SwiftUI's `Tab`.
typealias BrowserTab = BrowserCore.Tab

@main
struct QwaveIOSApp: App {
    @StateObject private var model = BrowserViewModel()

    var body: some Scene {
        WindowGroup {
            BrowserView(model: model)
                .preferredColorScheme(model.preferredColorScheme)
                .onOpenURL { url in
                    model.open(url)
                }
        }
    }
}

/// The iPhone browser shell: omnibox + tab strip + the WebKit view, with the
/// QwaveKit shields and the Rust core applied by the shared WebViewFactory.
@MainActor
final class BrowserViewModel: ObservableObject {
    @Published var tabs: [BrowserTab] = []
    @Published var activeTabID: UUID
    @Published var address: String = ""
    @Published var loading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var suggestions: [OmniboxSuggestion] = []
    /// Per-tab titles observed from WebKit (BrowserCore's Tab.title is
    /// owned by NavigationCoordinator on the desktop lane).
    @Published var tabTitles: [UUID: String] = [:]

    @Published var memoryNotice: String?
    private var memoryWave: WaveDirector?
    private var remembered: [MemoryRecord] = []

    let factory: WebViewFactory
    let settings: SettingsStore
    let energy: IOSEnergyPolicy

    /// SwiftUI's color scheme for the forced theme; nil follows the system.
    var preferredColorScheme: ColorScheme? {
        switch settings.themeMode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    private var suggestionTask: Task<Void, Never>?
    private var titleObservations: [UUID: NSKeyValueObservation] = [:]

    init() {
        let containers = ContainerRegistry(directory: QwaveDirectories.iosContainers)
        let compiler = RuleListCompiler()
        let shieldDirector = ShieldsDirector(
            compiler: compiler,
            policy: ShieldsPolicy(directory: QwaveDirectories.iosPolicy)
        )
        let featureFlags = FeatureFlagService()
        let settings = SettingsStore()
        let energy = IOSEnergyPolicy()
        self.settings = settings
        self.energy = energy
        factory = WebViewFactory(
            containers: containers,
            shields: shieldDirector,
            featureFlags: featureFlags,
            settings: settings
        )
        // Shields compile asynchronously; the first network navigation waits
        // (the factory's rule lists gate on the director).
        Task.detached(priority: .utility) {
            await shieldDirector.prepare()
        }
        energy.install()

        let firstTab = BrowserTab(pendingURL: settings.homepage ?? InternalPages.startURL)
        tabs = [firstTab]
        activeTabID = firstTab.id
        address = firstTab.pendingURL?.absoluteString ?? ""
        QwaveInternal.startPageHTML = { [weak self] in
            InternalPages.startHTML(
                memories: self?.remembered.map { StartMemoryChip(title: $0.title, preview: $0.url?.host ?? "Saved memory") } ?? [],
                providerLabel: "Saved page suggestions", deviceLabel: "this device only",
                showsTimeline: false, prompt: "Search or enter an address…")
        }
        Task { await prepareMemoryWave() }
    }

    private func prepareMemoryWave() async {
        do {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MemoryWave", isDirectory: true)
            let secrets = KeychainSecretStore()
            let store = try MemoryStore(directory: directory, secrets: secrets)
            memoryWave = WaveDirector(store: store, preferences: MemoryWavePreferences(secrets: secrets))
            await refreshMemories()
        } catch {
            QwaveLog.memory.error("iOS Memory Wave store unavailable: \(String(describing: error))")
            memoryNotice = "Memory Wave could not open its local store. Your saved data has not been replaced."
        }
    }

    private func refreshMemories() async {
        guard let memoryWave else { return }
        do {
            remembered = try await memoryWave.recall(containerID: nil, limit: 12)
            // Only refresh the local start page, never an unrelated browsing page.
            for tab in tabs where InternalPages.isStartURL(tab.webView?.url) {
                tab.webView?.reload()
            }
        } catch { memoryNotice = "Saved Memory Waves could not be loaded." }
    }

    func rememberCurrentPage() {
        guard let tab = tabs.first(where: { $0.id == activeTabID }),
              let url = tab.webView?.url, ExternalBrowserURL.isAllowed(url) else { return }
        let title = displayTitle(for: tab)
        Task {
            do {
                guard let memoryWave else { throw MemoryProviderError.unavailable }
                _ = try await memoryWave.remember(title: title, body: url.host ?? title, url: url,
                    containerID: nil, isEphemeral: tab.isEphemeral, isExplicit: true)
                await refreshMemories()
                memoryNotice = "Saved to Memory Wave on this device. Find it on your next new tab."
            } catch { memoryNotice = "This page could not be saved to Memory Wave." }
        }
    }

    func forgetMemories() {
        Task {
            do {
                guard let memoryWave else { throw MemoryProviderError.unavailable }
                try await memoryWave.forgetAll()
                await refreshMemories()
            } catch { memoryNotice = "Memory Waves could not be cleared. Please try again." }
        }
    }

    func submitWaveQuery(_ query: String) {
        // A saved suggestion opens its original page; its title is never sent to search.
        if let memory = remembered.first(where: { $0.title == query }) {
            if let url = memory.url, ExternalBrowserURL.isAllowed(url) { navigate(url.absoluteString) }
            else { memoryNotice = memory.body }
        } else { navigate(query) }
    }

    // MARK: - Tabs

    func open(_ url: URL) {
        // URLs delivered by another app may not invoke internal pages or scripts.
        guard ExternalBrowserURL.isAllowed(url) else { return }
        addTab(pendingURL: url)
    }

    func newTab() {
        addTab(pendingURL: InternalPages.startURL)
        Task { await refreshMemories() }
    }

    private func addTab(pendingURL: URL?) {
        evictIfNeeded()
        let tab = BrowserTab(pendingURL: pendingURL)
        tabs.append(tab)
        activeTabID = tab.id
        loading = false
        canGoBack = false
        canGoForward = false
        suggestions = []
        if let pendingURL {
            address = pendingURL.absoluteString
        }
    }

    func closeTab(_ id: UUID) {
        guard tabs.count > 1 else { return }
        titleObservations[id] = nil
        tabTitles[id] = nil
        tabs.removeAll { $0.id == id }
        if activeTabID == id {
            selectTab(tabs.last?.id ?? tabs[0].id)
        }
    }

    /// Battery policy: keep at most `energy.maxLiveTabs` tabs alive. The
    /// least-recently-activated background tab is evicted (its web view is
    /// released), so the page stops consuming memory and energy; reopening
    /// later reloads it. Never evicts the active tab.
    private func evictIfNeeded() {
        guard tabs.count >= energy.maxLiveTabs else { return }
        let evictable = tabs
            .filter { $0.id != activeTabID }
            .sorted { $0.lastActivated < $1.lastActivated }
        guard let victim = evictable.first else { return }
        closeTab(victim.id)
    }

    func selectTab(_ id: UUID) {
        guard activeTabID != id else { return }
        activeTabID = id
        tabs.first(where: { $0.id == id })?.noteActivated()
        if let active = tabs.first(where: { $0.id == id }) {
            address = active.url?.absoluteString ?? active.pendingURL?.absoluteString ?? ""
            canGoBack = active.webView?.canGoBack ?? false
            canGoForward = active.webView?.canGoForward ?? false
            loading = active.webView?.isLoading ?? false
        }
    }

    // MARK: - Web views

    func webView(for tab: BrowserTab) -> WKWebView {
        if let existing = tab.webView {
            existing.configuration.mediaTypesRequiringUserActionForPlayback = energy.autoplayPolicy
            return existing
        }
        let webView = factory.makeWebView(for: tab)
        webView.configuration.mediaTypesRequiringUserActionForPlayback = energy.autoplayPolicy
        observeTitle(of: webView, for: tab)
        return webView
    }

    /// The tab strip shows WebKit's live title (KVO) — the page knows its own
    /// title better than any heuristic.
    private func observeTitle(of webView: WKWebView, for tab: BrowserTab) {
        titleObservations[tab.id] = webView.observe(\.title, options: [.initial, .new]) { [weak self] webView, _ in
            Task { @MainActor [weak self] in
                if let title = webView.title, !title.isEmpty {
                    self?.tabTitles[tab.id] = title
                }
            }
        }
    }

    func displayTitle(for tab: BrowserTab) -> String {
        if let observed = tabTitles[tab.id], !observed.isEmpty { return observed }
        if let pending = tab.pendingURL { return pending.host ?? "New Tab" }
        if let url = tab.url { return url.host ?? "New Tab" }
        return "New Tab"
    }

    // MARK: - Navigation

    /// Navigate the address bar text. Falls back to the configured search
    /// engine when it is not a URL — Ecosia by default, never a hardcoded
    /// engine.
    func navigate(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let active = tabs.first(where: { $0.id == activeTabID }) else { return }
        let url: URL
        if let parsed = URL(string: trimmed), parsed.scheme != nil {
            url = parsed
        } else if trimmed.contains(".") && !trimmed.contains(" "),
            let direct = URL(string: "https://\(trimmed)")
        {
            url = direct
        } else {
            url = settings.searchEngine.searchURL(for: trimmed)
                ?? URL(string: "https://www.ecosia.org/search?q=\(trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")!
        }
        suggestions = []
        load(url, in: active)
    }

    private func load(_ url: URL, in tab: BrowserTab) {
        let webView = webView(for: tab)
        tab.pendingURL = url
        webView.load(URLRequest(url: url))
        address = url.absoluteString
    }

    func reload() {
        guard let active = tabs.first(where: { $0.id == activeTabID }) else { return }
        webView(for: active).reload()
    }

    func goBack() {
        guard let active = tabs.first(where: { $0.id == activeTabID }) else { return }
        let webView = webView(for: active)
        if webView.canGoBack { webView.goBack() }
    }

    func goForward() {
        guard let active = tabs.first(where: { $0.id == activeTabID }) else { return }
        let webView = webView(for: active)
        if webView.canGoForward { webView.goForward() }
    }

    // MARK: - Suggestions (on-device first, remote strictly opt-in)

    func updateSuggestions(_ raw: String) {
        suggestionTask?.cancel()
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            suggestions = []
            return
        }
        suggestionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }

            let openTabs = self.tabs.compactMap { tab -> OpenTabInfo? in
                guard tab.id != self.activeTabID, let url = tab.url ?? tab.pendingURL else { return nil }
                return OpenTabInfo(id: tab.id, title: self.displayTitle(for: tab), url: url)
            }

            // Remote suggestions: opt-in, engine-driven, and gated by the
            // Rust core's Category-A allowlist — the same decision the
            // desktop omnibox makes.
            let engine = self.settings.searchEngine
            let remote: [RemoteSearchSuggestion]
            if self.settings.networkSuggestionsEnabled,
                let provider = SearchSuggestionProviderFactory.provider(for: engine),
                let egressHost = SearchSuggestionProviderFactory.egressHost(for: engine),
                RustCore.egressPermits(egressHost)
            {
                remote = (try? await provider.fetchSuggestions(for: query)) ?? []
            } else {
                remote = []
            }

            let ranked = OmniboxSuggester.hybridSuggestions(
                for: query,
                history: [],
                openTabs: openTabs,
                actions: OmniboxAction.defaults,
                remoteSuggestions: remote,
                searchURLBuilder: { engine.searchURL(for: $0) }
            )
            guard !Task.isCancelled else { return }
            self.suggestions = ranked
        }
    }

    func commitSuggestion(_ suggestion: OmniboxSuggestion) {
        suggestions = []
        switch suggestion.kind {
        case .openTab(let id):
            selectTab(id)
        default:
            load(suggestion.url, in: tabs.first(where: { $0.id == activeTabID }) ?? tabs[0])
        }
    }

    // MARK: - Energy reactions

    /// Called when the energy tier changes (from the view's onChange): pause
    /// media everywhere on `.critical` and re-apply autoplay policy.
    func applyEnergyTier() {
        let autoplay = energy.autoplayPolicy
        for tab in tabs {
            tab.webView?.configuration.mediaTypesRequiringUserActionForPlayback = autoplay
            if energy.tier == .critical {
                if let webView = tab.webView {
                    energy.suspendMedia(in: webView)
                }
            }
        }
        evictIfNeeded()
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
