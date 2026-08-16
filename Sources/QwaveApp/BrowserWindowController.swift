import Summarize
import AppKit
import WebKit
import BrowserCore
import QwaveSupport
import Shields
import WebExtensions
import SwiftUI
import URLIdentity
import MemoryWave
import QwaveSupport
import WebCredentials
import QwaveUI
import os

/// One browser window: toolbar (navigation + omnibox + shields), tab strip,
/// and the web view container. Owns a `TabManager` and per-tab coordinators.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    let environment: BrowserEnvironment
    let tabManager: TabManager
    /// Private windows: every tab is ephemeral, nothing touches history or
    /// session restore, and the window frame is never autosaved.
    let isPrivate: Bool

    var onWindowClosed: ((BrowserWindowController) -> Void)?
    /// Fired on any change that affects the persisted session (tab add/close/
    /// move/select, navigation commit, pin). Debounced by the app's autosaver.
    var onSessionChange: (() -> Void)?

    private let tabBar = TabBarView()
    /// Arc-style vertical Spaces sidebar; lives alongside the horizontal strip
    /// and starts hidden (toggle via View ▸ Show Spaces Sidebar, ⌃⌘S).
    private let sidebar = SpacesSidebarView()
    private let containerView = WebViewContainerView()
    private let findBar = FindBarView()
    private let findController = FindInPageController()
    private let omnibox = OmniboxField()
    private let suggestions = OmniboxSuggestionsController()
    private let faviconLoader: FaviconLoader

    private var backButton: NSButton!
    private var forwardButton: NSButton!
    private var reloadButton: NSButton!
    private var shieldsButton: NSButton!
    private var extensionsButton: NSButton!
    private var memoryButton: NSButton!
    private var summarizeButton: NSButton!
    /// Downloads toolbar button; popover logic lives in DownloadsPopover.swift.
    var downloadsButton: NSButton!

    private var coordinators: [UUID: NavigationCoordinator] = [:]
    private var shieldsPopover: NSPopover?
    var downloadsPopover: NSPopover?
    private var extensionsPopup: ExtensionPopupController?
    private var memoryPopover: NSPopover?
    private var memoryPanelTitle = ""
    private var memoryPanelBody = ""
    private var memoryPanelFootnote = "Cognitive waves stay on this Mac."
    private var memoryBusy = false
    private var memoryAskDraft = ""
    private var summarizePopover: NSPopover?
    private var summarizeTitle = ""
    private var summarizeBody = ""
    private var summarizeFootnote = "On-device · text never leaves this Mac."
    private var summarizeBusy = false
    private var summarizeTask: Task<Void, Never>?
    /// In-flight omnibox suggestion query. Cancelled and replaced on each
    /// keystroke so a burst of typing collapses to a single debounced query.
    private var suggestionTask: Task<Void, Never>?
    private var lastAutoRemember: [UUID: (url: URL, at: Date)] = [:]
    /// Continuity/Handoff advertisement for the active tab. Only ever set for
    /// non-private, non-ephemeral http(s) pages (see HandoffPolicy); invalidated
    /// otherwise and on window close.
    private var browsingActivity: NSUserActivity?

    /// WebAuthn client: drives platform passkey ceremonies for pages in this
    /// window via ASAuthorizationController. Crypto-free and network-free — see
    /// PasskeyCeremonyController / WebAuthnBridge and docs/AUTOFILL.md.
    private lazy var passkeyCeremony = PasskeyCeremonyController(presentationWindow: window)
    private lazy var webAuthnBridge = WebAuthnBridge(ceremony: passkeyCeremony)

    /// Shared keychain-backed login store. Same access-group convention as
    /// `CredentialProviderViewController` (`accessGroup: nil` resolves to the
    /// single shared `keychain-access-groups` entitlement), so a login the
    /// browser saves here is exactly what the extension fills.
    private let webCredentialStore: any WebCredentialStore = KeychainWebCredentialStore(accessGroup: nil)
    /// The write path issue #72 found missing: routes a save/remove through
    /// both the keychain store above and the system's AutoFill identity index.
    private lazy var credentialSaver = CredentialSaver(
        store: webCredentialStore,
        identitySync: SystemCredentialIdentityStore(),
        onIdentitySyncError: { [log = credentialLog] error in
            log.error("credential identity sync failed: \(String(describing: error), privacy: .public)")
        }
    )
    private let credentialLog = Logger(subsystem: "is.8b.qwave", category: "credential-save")
    /// Detects password-form submissions and prompts to save them. See
    /// docs/AUTOFILL.md and PasswordCaptureBridge.swift.
    private lazy var passwordCaptureBridge = PasswordCaptureBridge(
        saver: credentialSaver,
        existingCredentials: { [webCredentialStore] domain in
            (try? webCredentialStore.credentials(forDomain: domain)) ?? []
        }
    )

    // MARK: - Init

    init(environment: BrowserEnvironment, tabManager: TabManager? = nil, isPrivate: Bool = false) {
        self.environment = environment
        self.tabManager = tabManager ?? TabManager()
        self.isPrivate = isPrivate
        self.faviconLoader = FaviconLoader(store: environment.favicons)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.tabbingMode = .disallowed
        window.center()
        if isPrivate {
            // No frame autosave: private geometry must not resurrect into
            // (or leak from) normal windows' saved frames.
            window.appearance = NSAppearance(named: .darkAqua)
        } else {
            window.setFrameAutosaveName("QwaveBrowserWindow")
        }
        super.init(window: window)

        window.delegate = self
        setupToolbar()
        setupTabBarAccessory()
        setupContent()
        wireTabManager()
        wireTabBar()
        wireSidebar()
        wireFindBar()
        wireSuggestions()
        // Toolbar items materialise lazily; the summarize button may not exist
        // yet, so refresh again once the window is on screen (vanish-cleanly).
        DispatchQueue.main.async { [weak self] in self?.refreshSummarizePresence() }

        if self.tabManager.isEmpty {
            appendFreshTab(activate: true)
        }
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not supported")
    }

    // MARK: - Setup

    private func setupToolbar() {
        let toolbar = NSToolbar(identifier: "QwaveToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
    }

    private func setupTabBarAccessory() {
        let accessory = NSTitlebarAccessoryViewController()
        tabBar.frame = NSRect(x: 0, y: 0, width: 800, height: 34)
        accessory.view = tabBar
        accessory.layoutAttribute = .bottom
        accessory.fullScreenMinHeight = 34
        window?.addTitlebarAccessoryViewController(accessory)
    }

    private func setupContent() {
        guard let contentView = window?.contentView else { return }

        findBar.isHidden = true
        findBar.translatesAutoresizingMaskIntoConstraints = false
        containerView.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [findBar, containerView])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Sidebar starts collapsed; a hidden arranged view contributes no width.
        sidebar.isHidden = true
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        let columns = NSStackView(views: [sidebar, stack])
        columns.orientation = .horizontal
        columns.spacing = 0
        columns.distribution = .fill
        columns.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(columns)

        NSLayoutConstraint.activate([
            columns.topAnchor.constraint(equalTo: contentView.topAnchor),
            columns.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            columns.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            columns.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 220),
            findBar.heightAnchor.constraint(equalToConstant: 30),
            findBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            containerView.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func wireTabManager() {
        tabManager.onChange = { [weak self] in
            self?.render()
            self?.onSessionChange?()
        }
        tabManager.onTabClosed = { [weak self] tab in
            self?.teardown(tab: tab)
        }
    }

    private func wireTabBar() {
        tabBar.onSelect = { [weak self] id in
            self?.tabManager.select(tabID: id)
        }
        tabBar.onClose = { [weak self] id in
            self?.tabManager.close(tabID: id)
        }
        tabBar.onNewTab = { [weak self] in
            self?.appendFreshTab(activate: true)
        }
        tabBar.onNewContainerTab = { [weak self] containerID in
            let isEphemeral = containerID == ContainerRegistry.ephemeralProfileID
            self?.openNewTab(url: nil, containerID: containerID, ephemeral: isEphemeral, activate: true)
        }
        tabBar.containerProvider = { [weak self] in
            (self?.environment.containers.profiles ?? []).map { ($0.id, $0.name) }
        }
        tabBar.onReorder = { [weak self] from, to in
            self?.tabManager.move(fromIndex: from, toIndex: to)
        }
        containerView.onDropFile = { [weak self] url in
            self?.openNewTab(url: url, activate: true)
        }
    }

    private func wireSidebar() {
        sidebar.onSelectSpace = { [weak self] spaceID in
            self?.selectSpace(spaceID)
        }
        sidebar.onSelectTab = { [weak self] id in
            self?.tabManager.select(tabID: id)
        }
        sidebar.onCloseTab = { [weak self] id in
            self?.tabManager.close(tabID: id)
        }
        sidebar.onNewTab = { [weak self] spaceID in
            self?.openNewTab(url: nil, containerID: spaceID, ephemeral: false, activate: true)
        }
    }

    /// Switches the window's active Space (container). Activates the first
    /// existing tab in that Space, or opens a fresh one there when empty —
    /// which switches the visible container store for the window.
    private func selectSpace(_ spaceID: UUID?) {
        let placements = tabManager.tabs.map {
            TabPlacement(id: $0.id, containerID: $0.containerID, isEphemeral: $0.isEphemeral)
        }
        if let first = SpacesLayout.firstTabID(inSpace: spaceID, tabs: placements) {
            tabManager.select(tabID: first)
        } else {
            openNewTab(url: nil, containerID: spaceID, ephemeral: false, activate: true)
        }
    }

    /// Rebuilds the sidebar's Space chips and the active Space's vertical tab
    /// list. The active Space is derived from the selected tab's container so
    /// the sidebar and the shown page never disagree; an ephemeral/private tab
    /// highlights no Space and the list falls back to the default Space.
    private func updateSidebar() {
        guard !sidebar.isHidden else { return }
        let placements = tabManager.tabs.map {
            TabPlacement(id: $0.id, containerID: $0.containerID, isEphemeral: $0.isEphemeral)
        }
        let selected = tabManager.selectedTab
        let activeSpaceID = (selected?.isEphemeral == true) ? nil : selected?.containerID
        let hasActiveSpace = selected != nil && selected?.isEphemeral == false

        let chips = SpacesLayout.spaces(from: environment.containers.profiles).map { descriptor in
            SpaceChipModel(
                id: descriptor.id,
                name: descriptor.name,
                colorHex: descriptor.colorHex,
                tabCount: SpacesLayout.tabIDs(inSpace: descriptor.id, tabs: placements).count,
                isActive: hasActiveSpace && descriptor.id == activeSpaceID
            )
        }

        let listSpaceID = activeSpaceID
        let visibleTabIDs = Set(SpacesLayout.tabIDs(inSpace: listSpaceID, tabs: placements))
        let tabModels = tabModels(for: tabManager.tabs.filter { visibleTabIDs.contains($0.id) })
        sidebar.update(
            spaces: chips,
            tabs: tabModels,
            selectedID: tabManager.selectedTabID,
            listSpaceID: listSpaceID
        )
    }

    /// Toolbar/menu action: show or hide the vertical Spaces sidebar.
    @objc func toggleSpacesSidebar(_ sender: Any?) {
        sidebar.isHidden.toggle()
        updateSidebar()
    }

    private func wireSuggestions() {
        omnibox.delegate = self
        suggestions.onCommit = { [weak self] suggestion in
            guard let self else { return }
            self.suggestions.hide()
            // A "switch to open tab" row activates the existing tab instead of
            // reloading its URL.
            if case .openTab(let id) = suggestion.kind {
                self.tabManager.select(tabID: id)
                self.omnibox.stringValue = self.tabManager.selectedTab?.url?.absoluteString ?? ""
                self.window?.makeFirstResponder(self.containerView)
                return
            }
            self.omnibox.stringValue = suggestion.url.absoluteString
            self.omniboxCommitted(nil)
        }
    }

    private func wireFindBar() {
        findBar.onSearch = { [weak self] query, forward in
            guard let self, let webView = self.tabManager.selectedTab?.webView else { return }
            self.findController.find(query, in: webView, forward: forward) { _ in }
        }
        findBar.onClose = { [weak self] in
            self?.hideFindBar()
        }
    }

    // MARK: - Tabs

    private func defaultNewTabURL() -> URL {
        if isPrivate { return InternalPages.startURL }
        return environment.settings.homepage ?? InternalPages.startURL
    }

    private func appendFreshTab(activate: Bool) {
        let tab =
            isPrivate
            ? Tab(
                containerID: ContainerRegistry.ephemeralProfileID, isEphemeral: true,
                pendingURL: InternalPages.startURL)
            : Tab(pendingURL: defaultNewTabURL())
        tabManager.append(tab, select: activate)
        if activate {
            focusOmnibox()
        }
    }

    func openNewTab(
        url: URL?,
        containerID: UUID? = nil,
        ephemeral: Bool = false,
        activate: Bool = true
    ) {
        // Every tab in a private window is ephemeral, whatever the caller asked.
        let makeEphemeral = ephemeral || isPrivate
        let tab = Tab(
            containerID: makeEphemeral ? ContainerRegistry.ephemeralProfileID : containerID,
            isEphemeral: makeEphemeral,
            pendingURL: url ?? (makeEphemeral ? InternalPages.startURL : defaultNewTabURL())
        )
        tabManager.insertAfterSelection(tab, select: activate)
        if activate, url == nil {
            focusOmnibox()
        }
    }

    /// Builds (or restores) the web view for a tab, wiring its coordinator.
    private func ensureWebView(for tab: BrowserCore.Tab) -> WKWebView {
        if let existing = tab.webView {
            return existing
        }

        let record = tab.hibernationRecord
        let webView = environment.factory.makeWebView(for: tab)
        // WebExtensions MV3 bridge: browser.* API for content scripts.
        environment.extensions.installBridge(into: webView.configuration.userContentController)
        // WebAuthn passkey bridge: exposes window.__qwavePasskeyGet/Create so a
        // page can drive a platform passkey ceremony through the app.
        let userContent = webView.configuration.userContentController
        userContent.add(webAuthnBridge, name: WebAuthnBridge.messageName)
        userContent.addUserScript(WebAuthnBridge.userScript)
        // Password-save capture: detects a submitted login form and, on
        // confirmation, writes it to the keychain + AutoFill identity index
        // (see docs/AUTOFILL.md, issue #72). Skipped for every ephemeral tab,
        // not only for private windows — a normal window can hold an ephemeral
        // tab (Cmd-Opt-T), and an ephemeral tab must never persist a login.
        // Installed into the bridge's own content world so page JS can neither
        // forge a capture message nor suppress the shim.
        if PasswordCapturePolicy.captureIsAllowed(isPrivateWindow: isPrivate, isEphemeralTab: tab.isEphemeral) {
            userContent.add(
                passwordCaptureBridge,
                contentWorld: PasswordCaptureBridge.contentWorld,
                name: PasswordCaptureBridge.messageName
            )
            userContent.addUserScript(PasswordCaptureBridge.userScript)
        }

        let coordinator = coordinators[tab.id] ?? environment.makeCoordinator(for: tab)
        coordinators[tab.id] = coordinator
        coordinator.onOpenNewTab = { [weak self, weak tab] url, activate in
            self?.openNewTab(
                url: url,
                containerID: tab?.containerID,
                ephemeral: tab?.isEphemeral ?? false,
                activate: activate
            )
        }
        coordinator.onStateChange = { [weak self] in
            self?.setChromeNeedsRefresh()
            self?.onSessionChange?()
        }
        coordinator.onInternalAction = { [weak self] action in
            self?.handleInternalAction(action)
        }
        coordinator.onMainFrameFinished = { [weak self] webView, finishedTab in
            self?.autoRememberIfNeeded(webView: webView, tab: finishedTab)
        }
        coordinator.onFaviconURL = { [weak self, weak tab] iconURL in
            guard let self, let tab else { return }
            self.faviconLoader.load(
                iconURL: iconURL,
                pageHost: tab.url.flatMap(CanonicalHost.host(of:)),
                containerID: tab.containerID
            ) { [weak self, weak tab] image in
                guard let image, let tab else { return }
                tab.favicon = image
                self?.refreshChromeState()
            }
        }
        coordinator.attach(to: webView)

        // Restoring interactionState reloads the current back/forward item with
        // its scroll position, so no separate load() is needed. Precedence:
        // a hibernation record, then a session/reopen-restored pending state,
        // then a plain URL load.
        if let state = record?.interactionState ?? tab.pendingInteractionState {
            tab.pendingInteractionState = nil
            tab.pendingURL = nil
            webView.interactionState = state
        } else if let pending = tab.pendingURL ?? record?.url {
            tab.pendingURL = nil
            webView.load(URLRequest(url: pending))
        }
        return webView
    }

    private func teardown(tab: BrowserCore.Tab) {
        coordinators[tab.id]?.detach()
        coordinators.removeValue(forKey: tab.id)
        if let webView = tab.webView {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.removeFromSuperview()
        }
    }

    // MARK: - Rendering

    /// Builds display models for a set of tabs, shared by the horizontal strip
    /// and the vertical sidebar.
    private func tabModels(for tabs: [BrowserCore.Tab]) -> [TabDisplayModel] {
        tabs.map { tab in
            TabDisplayModel(
                id: tab.id,
                title: tab.displayTitle,
                isPinned: tab.isPinned,
                isHibernated: tab.isHibernated,
                isLoading: tab.isLoading,
                isEphemeral: tab.isEphemeral,
                containerColorHex: environment.containers.profile(withID: tab.containerID)?.colorHex,
                favicon: tab.favicon
                    ?? faviconLoader.cachedIcon(
                        forHost: tab.url.flatMap(CanonicalHost.host(of:)), containerID: tab.containerID)
            )
        }
    }

    private func render() {
        if tabManager.isEmpty {
            appendFreshTab(activate: true)
            return
        }

        let models = tabModels(for: tabManager.tabs)
        tabBar.update(tabs: models, selectedID: tabManager.selectedTabID)
        updateSidebar()

        if let selected = tabManager.selectedTab {
            let webView = ensureWebView(for: selected)
            containerView.show(webView)
        }
        refreshChromeState()
    }

    private var chromeRefreshScheduled = false

    /// Coalesces chrome refreshes to one per runloop turn. A page load fires a
    /// burst of KVO ticks — `estimatedProgress` especially, which drives no
    /// visible chrome — and each one would otherwise rebuild the whole tab-model
    /// array. The first request in a turn schedules a single refresh; the rest
    /// are no-ops until it fires, so a burst collapses to one refresh with the
    /// same visible result. Explicit one-off refreshes (render, favicon, shields
    /// toggles) still call `refreshChromeState()` directly.
    private func setChromeNeedsRefresh() {
        guard !chromeRefreshScheduled else { return }
        chromeRefreshScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.chromeRefreshScheduled = false
            self.refreshChromeState()
        }
    }

    private func refreshChromeState() {
        // P0 instrumentation: fired from every NavigationCoordinator KVO tick
        // (incl. estimatedProgress). The interval count per page load in an
        // Instruments capture is the coalescing target. See docs/PERF.md.
        let signpostID = QwaveSignposts.browser.makeSignpostID()
        let interval = QwaveSignposts.browser.beginInterval("chrome-refresh", id: signpostID)
        defer { QwaveSignposts.browser.endInterval("chrome-refresh", interval) }

        guard let selected = tabManager.selectedTab else { return }
        let webView = selected.webView

        window?.title = isPrivate ? "🕶 Private — \(selected.displayTitle)" : selected.displayTitle
        updateHandoff(url: selected.url, isEphemeralTab: selected.isEphemeral)
        backButton?.isEnabled = webView?.canGoBack ?? false
        forwardButton?.isEnabled = webView?.canGoForward ?? false

        let isEditingOmnibox =
            window?.firstResponder is NSTextView
            && omnibox.currentEditor() === (window?.firstResponder as? NSTextView)
        if !isEditingOmnibox {
            if InternalPages.isStartURL(selected.url) {
                omnibox.stringValue = ""
            } else {
                omnibox.stringValue = selected.url?.absoluteString ?? ""
            }
        }

        if let button = reloadButton {
            let symbol = selected.isLoading ? "xmark" : "arrow.clockwise"
            button.image = NSImage(
                systemSymbolName: symbol, accessibilityDescription: selected.isLoading ? "Stop" : "Reload")
        }

        if let button = shieldsButton {
            let host = selected.url.flatMap(CanonicalHost.host(of:))
            let blocked = environment.shieldsPolicy.resolvedPolicy(forHost: host).adsBlocked
            button.image = NSImage(
                systemSymbolName: blocked ? "shield.fill" : "shield.slash",
                accessibilityDescription: "Shields"
            )
            button.contentTintColor = blocked ? nil : .systemOrange
        }

        // Refresh the tab strip labels (title/loading changed).
        tabBar.update(tabs: tabModels(for: tabManager.tabs), selectedID: tabManager.selectedTabID)
        updateSidebar()
    }

    private func focusOmnibox() {
        window?.makeFirstResponder(omnibox)
    }

    // MARK: - Energy

    func applyEnergyPolicy(
        _ policy: EnergyPolicy,
        hibernation: HibernationController,
        hibernator: TabHibernator
    ) async {
        let selectedIsLoading = tabManager.selectedTab?.isLoading ?? false
        var infos: [TabHibernationInfo] = []
        for tab in tabManager.tabs {
            let isSelected = tab.id == tabManager.selectedTabID
            var isPlaying = false
            // Skip the media-playback IPC for the selected tab: its result is
            // discarded on both consumers (applyMediaPolicy guards !isSelected;
            // tabsToHibernate exempts the selected tab), so probing it is pure
            // per-tick main-thread round-trip waste. Non-selected tabs still get
            // the probe so their background-media policy is applied.
            if let webView = tab.webView, !isSelected {
                isPlaying = await mediaPlaybackState(of: webView) == .playing
                if !isPlaying {
                    hibernator.applyMediaPolicy(policy, to: tab, isSelected: isSelected)
                }
            }
            infos.append(
                TabHibernationInfo(
                    id: tab.id,
                    isSelected: isSelected,
                    isPinned: tab.isPinned,
                    isPlayingMedia: isPlaying,
                    isHibernatable: tab.webView != nil,
                    lastActivated: tab.lastActivated,
                    isLoading: tab.isLoading
                )
            )
        }

        let victims = hibernation.tabsToHibernate(
            now: Date(), tabs: infos, foregroundIsLoading: selectedIsLoading)
        guard !victims.isEmpty else { return }
        for id in victims {
            if let tab = tabManager.tab(withID: id) {
                coordinators[id]?.detach()
                await hibernator.hibernate(tab)
            }
        }
        render()
    }

    private func mediaPlaybackState(of webView: WKWebView) async -> WKMediaPlaybackState {
        await withCheckedContinuation { continuation in
            webView.requestMediaPlaybackState { state in
                continuation.resume(returning: state)
            }
        }
    }

    // MARK: - Omnibox

    @objc private func omniboxCommitted(_ sender: Any?) {
        suggestions.hide()
        let input = OmniboxParser.parse(omnibox.stringValue)
        let target: URL?
        switch input {
        case .url(let url):
            target = url
        case .search(let query):
            guard !query.isEmpty else { return }
            target = environment.settings.searchEngine.searchURL(for: query)
        }
        guard let target, let selected = tabManager.selectedTab else { return }
        ensureWebView(for: selected).load(URLRequest(url: target))
        window?.makeFirstResponder(containerView)
    }

    // MARK: - Menu / toolbar actions

    @objc func newTab(_ sender: Any?) { appendFreshTab(activate: true) }

    /// ⇧⌘T — reopen the most recently closed tab (with its history + scroll).
    @objc func reopenClosedTab(_ sender: Any?) {
        tabManager.reopenLastClosedTab()
    }

    @objc func newEphemeralTab(_ sender: Any?) {
        openNewTab(url: nil, ephemeral: true, activate: true)
    }

    @objc func closeTab(_ sender: Any?) {
        guard let selected = tabManager.selectedTab else { return }
        if tabManager.count == 1 {
            window?.performClose(sender)
        } else {
            tabManager.close(tabID: selected.id)
        }
    }

    @objc func openLocation(_ sender: Any?) { focusOmnibox() }

    @objc func reload(_ sender: Any?) {
        guard let selected = tabManager.selectedTab else { return }
        if selected.isLoading {
            selected.webView?.stopLoading()
        } else {
            ensureWebView(for: selected).reload()
        }
    }

    @objc func stopLoading(_ sender: Any?) {
        tabManager.selectedTab?.webView?.stopLoading()
    }

    @objc func goBack(_ sender: Any?) { tabManager.selectedTab?.webView?.goBack() }
    @objc func goForward(_ sender: Any?) { tabManager.selectedTab?.webView?.goForward() }

    @objc func showWebInspector(_ sender: Any?) {
        guard let webView = tabManager.selectedTab?.webView else { return }
        WebInspector.show(for: webView)
    }

    @objc func showJavaScriptConsole(_ sender: Any?) {
        guard let webView = tabManager.selectedTab?.webView else { return }
        WebInspector.showConsole(for: webView)
    }

    @objc func zoomIn(_ sender: Any?) {
        guard let webView = tabManager.selectedTab?.webView else { return }
        webView.pageZoom = min(webView.pageZoom + 0.1, 3.0)
    }

    @objc func zoomOut(_ sender: Any?) {
        guard let webView = tabManager.selectedTab?.webView else { return }
        webView.pageZoom = max(webView.pageZoom - 0.1, 0.4)
    }

    @objc func actualSize(_ sender: Any?) {
        tabManager.selectedTab?.webView?.pageZoom = 1.0
    }

    @objc func showFindBar(_ sender: Any?) {
        findBar.isHidden = false
        window?.makeFirstResponder(findBar.searchField)
    }

    private func hideFindBar() {
        findBar.isHidden = true
        window?.makeFirstResponder(containerView)
    }

    @objc func findNext(_ sender: Any?) {
        guard let webView = tabManager.selectedTab?.webView else { return }
        findController.findNext(in: webView) { _ in }
    }

    @objc func findPrevious(_ sender: Any?) {
        guard let webView = tabManager.selectedTab?.webView else { return }
        findController.findPrevious(in: webView) { _ in }
    }

    @objc func addBookmark(_ sender: Any?) {
        guard let selected = tabManager.selectedTab, let url = selected.url else { return }
        Task { @MainActor [weak self] in
            if let bookmark = try? await self?.environment.bookmarks?.add(title: selected.displayTitle, url: url) {
                self?.environment.invalidateBookmarkCache()
                // Surface the new bookmark to Spotlight (Command+Space search).
                await SpotlightIndexer.index(bookmark)
            }
        }
    }

    @objc func selectNextTab(_ sender: Any?) { tabManager.selectNext() }
    @objc func selectPreviousTab(_ sender: Any?) { tabManager.selectPrevious() }

    @objc func togglePinTab(_ sender: Any?) {
        guard let selected = tabManager.selectedTab else { return }
        selected.isPinned.toggle()
        render()
        onSessionChange?()
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.openNewTab(url: url, activate: true)
        }
    }

    @objc func rememberSelection(_ sender: Any?) {
        Task { await rememberCurrentSelection() }
    }

    private func handleInternalAction(_ action: QwaveInternalAction) {
        switch action {
        case .submit(let query):
            let parsed = OmniboxParser.parse(query)
            switch parsed {
            case .url(let url):
                guard let selected = tabManager.selectedTab else { return }
                ensureWebView(for: selected).load(URLRequest(url: url))
            case .search(let text):
                Task { await askStartQuery(text) }
            }
        case .remember(let scope, let text):
            Task { await rememberText(text, scope: scope) }
        case .summarize(let range):
            Task { await summarizeTimeline(range) }
        }
    }

    @objc func openNibbleFolder(_ sender: Any?) {
        if let directory = environment.memoryWave.vault?.directory {
            NSWorkspace.shared.open(directory)
        }
    }

    @objc func showTimeline(_ sender: Any?) {
        let controller = (NSApp.delegate as? AppDelegate)?.frontmostBrowserWindow ?? self
        let tab = controller.tabManager.selectedTab
        if let tab {
            controller.ensureWebView(for: tab).load(URLRequest(url: InternalPages.timelineURL))
        } else {
            controller.openNewTab(url: InternalPages.timelineURL, activate: true)
        }
    }

    private func autoRememberIfNeeded(webView: WKWebView, tab: BrowserCore.Tab) {
        guard environment.memoryPreferences.rememberEverything, !tab.isEphemeral else { return }
        guard let url = webView.url, url.scheme == "http" || url.scheme == "https" else { return }
        if let previous = lastAutoRemember[tab.id], previous.url == url, Date().timeIntervalSince(previous.at) < 45 {
            return
        }
        lastAutoRemember[tab.id] = (url, Date())
        Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }
            let result = try? await webView.evaluateJavaScript(ArticleExtractor.userScript)
            let extract =
                result.flatMap(ArticleExtractor.decode)
                ?? ArticleExtract(title: tab.title, text: tab.title, href: url.absoluteString)
            let title = extract.title.isEmpty ? (url.host ?? "Page") : extract.title
            _ = try? await self.environment.memoryWave.remember(
                title: title,
                body: extract.text,
                url: url,
                kind: .browse,
                containerID: tab.containerID,
                isEphemeral: tab.isEphemeral,
                isExplicit: false
                // No provenance argument: automatic capture of page text with
                // no per-record user decision stays at the default, `.derived`.
            )
        }
    }

    private func summarizeTimeline(_ raw: String) async {
        let range = TimelineRange(rawValue: raw) ?? .today
        memoryBusy = true
        showMemoryWaveIfNeeded()
        refreshMemoryPopover()
        defer {
            memoryBusy = false
            refreshMemoryPopover()
        }
        do {
            let answer = try await environment.memoryWave.summarizeTimeline(
                range: range, inferenceAllowed: inferenceAllowed(), persist: true)
            QwaveInternal.lastTimelineSummary = answer.text
            memoryPanelTitle = "Timeline · \(range.displayName)"
            memoryPanelBody = answer.text
            memoryPanelFootnote = "Local slate · \(answer.provider.rawValue)"
            if let tab = tabManager.selectedTab {
                ensureWebView(for: tab).load(URLRequest(url: InternalPages.timelineURL))
            }
        } catch MemoryProviderError.denied(let reason) {
            memoryPanelBody = denialMessage(reason)
        } catch MemoryProviderError.unavailable {
            memoryPanelBody = "Pick a provider in Settings → Memory Wave to write the slate."
        } catch {
            memoryPanelBody = "Could not summarize the timeline."
        }
    }

    private func askStartQuery(_ text: String) async {
        guard let tab = tabManager.selectedTab else { return }
        memoryAskDraft = text
        memoryBusy = true
        showMemoryWaveIfNeeded()
        refreshMemoryPopover()
        defer {
            memoryBusy = false
            refreshMemoryPopover()
        }
        do {
            let answer = try await environment.memoryWave.ask(
                prompt: text,
                page: nil,
                containerID: tab.containerID,
                isEphemeral: tab.isEphemeral,
                inferenceAllowed: inferenceAllowed()
            )
            memoryPanelTitle = "Ask"
            memoryPanelBody = answer.text
            memoryPanelFootnote = "Start page · memories stay local"
        } catch MemoryProviderError.denied(let reason) {
            memoryPanelBody = denialMessage(reason)
        } catch MemoryProviderError.unavailable {
            if let search = environment.settings.searchEngine.searchURL(for: text) {
                ensureWebView(for: tab).load(URLRequest(url: search))
                return
            }
            memoryPanelBody = "No inference provider. Settings → Memory Wave, or search from the omnibox."
        } catch {
            memoryPanelBody = "Ask failed."
        }
    }

    private func rememberText(_ text: String, scope: String) async {
        guard let tab = tabManager.selectedTab else { return }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            memoryPanelBody = "Nothing selected."
            showMemoryWaveIfNeeded()
            refreshMemoryPopover()
            return
        }
        let title: String
        if scope == "selection" {
            title = "Selection · \(tab.displayTitle)"
        } else {
            title = tab.displayTitle
        }
        do {
            _ = try await environment.memoryWave.remember(
                title: title,
                body: body,
                url: tab.url,
                kind: scope == "selection" ? .note : .pin,
                containerID: tab.containerID,
                isEphemeral: tab.isEphemeral,
                // The user picked this text and asked for it to be kept.
                provenance: .authored
            )
            memoryPanelTitle = title
            memoryPanelBody =
                scope == "selection"
                ? "Remembered the selection as a Cognitive wave." : "Remembered the page as a Cognitive wave."
            memoryPanelFootnote = "Odd lane · encrypted · this Mac only."
        } catch MemoryProviderError.denied(.ephemeral) {
            memoryPanelBody = "Ephemeral and private tabs never write to Memory Wave."
        } catch {
            memoryPanelBody = "Could not store that memory."
        }
        showMemoryWaveIfNeeded()
        refreshMemoryPopover()
    }

    private func rememberCurrentSelection() async {
        guard let webView = tabManager.selectedTab?.webView else { return }
        let script = """
            (function() {
              const sel = window.getSelection() ? window.getSelection().toString() : '';
              if (sel) return sel;
              const src = document.getElementById('qwave-source');
              return src ? src.textContent : '';
            })()
            """
        let value = try? await webView.evaluateJavaScript(script)
        let text = value as? String ?? ""
        await rememberText(text, scope: "selection")
    }

    @objc func rememberThisPage(_ sender: Any?) {
        Task { await rememberSelectedPage() }
    }

    @objc func summarizePage(_ sender: Any?) {
        Task { await summarizeSelectedPage(persist: false) }
    }

    @objc func askMemoryWave(_ sender: Any?) {
        showMemoryWave(sender)
        window?.makeFirstResponder(nil)
    }

    @objc func toggleMemoryWave(_ sender: Any?) {
        showMemoryWave(sender)
    }

    private func showMemoryWave(_ sender: Any?) {
        guard let button = memoryButton else { return }
        if let popover = memoryPopover, popover.isShown {
            popover.close()
            memoryPopover = nil
            return
        }
        presentMemoryPopover(relativeTo: button)
    }

    private func presentMemoryPopover(relativeTo button: NSButton) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: memoryPanelRoot())
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        memoryPopover = popover
    }

    private func memoryPanelRoot() -> MemoryWavePanelView {
        MemoryWavePanelView(
            title: memoryPanelTitle,
            bodyText: memoryPanelBody,
            footnote: memoryPanelFootnote,
            isBusy: memoryBusy,
            askDraft: Binding(
                get: { self.memoryAskDraft },
                set: { self.memoryAskDraft = $0 }
            ),
            onAsk: { Task { await self.askSelectedPage() } },
            onRemember: { Task { await self.rememberSelectedPage() } },
            onSummarize: { Task { await self.summarizeSelectedPage(persist: true) } }
        )
    }

    private func refreshMemoryPopover() {
        guard let popover = memoryPopover, popover.isShown,
            let button = memoryButton
        else { return }
        popover.contentViewController = NSHostingController(rootView: memoryPanelRoot())
        _ = button
    }

    private func inferenceAllowed() -> Bool {
        (NSApp.delegate as? AppDelegate)?.inferenceAllowedNow() ?? true
    }

    private func extractSelectedPage() async -> ArticleExtract? {
        guard let tab = tabManager.selectedTab else { return nil }
        let webView = ensureWebView(for: tab)
        do {
            let result: Any = try await webView.evaluateJavaScript(ArticleExtractor.userScript)
            if let extract = ArticleExtractor.decode(result) {
                return extract
            }
        } catch {
            QwaveLog.memory.warning("article extract script failed")
        }
        if let url = tab.url {
            return ArticleExtract(title: tab.displayTitle, text: tab.title, href: url.absoluteString)
        }
        return nil
    }

    private func rememberSelectedPage() async {
        guard let tab = tabManager.selectedTab else { return }
        memoryBusy = true
        refreshMemoryPopover()
        defer {
            memoryBusy = false
            refreshMemoryPopover()
        }
        guard let extract = await extractSelectedPage() else {
            memoryPanelBody = "Nothing to remember on this tab."
            return
        }
        do {
            _ = try await environment.memoryWave.remember(
                title: extract.title,
                body: extract.text,
                url: extract.href.flatMap(URL.init(string:)) ?? tab.url,
                kind: .pin,
                containerID: tab.containerID,
                isEphemeral: tab.isEphemeral,
                // Explicit Remember of a page the user chose. The body is page
                // text, but the decision to keep it was the user's.
                provenance: .authored
            )
            memoryPanelTitle = extract.title
            memoryPanelBody = "Remembered as a Cognitive wave in this container."
            memoryPanelFootnote = "Odd lane · encrypted · this Mac only."
        } catch MemoryProviderError.denied(.ephemeral) {
            memoryPanelBody = "Ephemeral and private tabs never write to Memory Wave."
        } catch {
            memoryPanelBody = "Could not store that memory."
        }
        showMemoryWaveIfNeeded()
    }

    private func summarizeSelectedPage(persist: Bool) async {
        guard let tab = tabManager.selectedTab else { return }
        memoryBusy = true
        showMemoryWaveIfNeeded()
        refreshMemoryPopover()
        defer {
            memoryBusy = false
            refreshMemoryPopover()
        }
        guard let extract = await extractSelectedPage() else {
            memoryPanelBody = "Could not read the page."
            return
        }
        do {
            let answer = try await environment.memoryWave.summarize(
                extract: extract,
                containerID: tab.containerID,
                isEphemeral: tab.isEphemeral,
                inferenceAllowed: inferenceAllowed(),
                persist: persist && !tab.isEphemeral
            )
            memoryPanelTitle = extract.title
            memoryPanelBody = answer.text
            memoryPanelFootnote =
                persist
                ? "Summary saved locally. Provider: \(answer.provider.rawValue)."
                : "Not saved. Provider: \(answer.provider.rawValue)."
        } catch MemoryProviderError.denied(let reason) {
            memoryPanelBody = denialMessage(reason)
        } catch MemoryProviderError.unavailable {
            memoryPanelBody = "No inference provider is configured. Remember still works."
        } catch {
            memoryPanelBody = "Summarize failed."
        }
    }

    private func askSelectedPage() async {
        guard let tab = tabManager.selectedTab else { return }
        let prompt = memoryAskDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        memoryBusy = true
        showMemoryWaveIfNeeded()
        refreshMemoryPopover()
        defer {
            memoryBusy = false
            refreshMemoryPopover()
        }
        let extract = await extractSelectedPage()
        do {
            let answer = try await environment.memoryWave.ask(
                prompt: prompt,
                page: extract,
                containerID: tab.containerID,
                isEphemeral: tab.isEphemeral,
                inferenceAllowed: inferenceAllowed()
            )
            memoryPanelTitle = extract?.title ?? "Ask"
            memoryPanelBody = answer.text
            memoryPanelFootnote =
                answer.usedStoredMemory
                ? "Answer used local Cognitive waves (on-device only)."
                : "Stored memories were not sent."
        } catch MemoryProviderError.denied(let reason) {
            memoryPanelBody = denialMessage(reason)
        } catch MemoryProviderError.unavailable {
            memoryPanelBody = "No inference provider is configured. Settings → Memory Wave."
        } catch {
            memoryPanelBody = "Ask failed."
        }
    }

    private func showMemoryWaveIfNeeded() {
        guard memoryPopover?.isShown != true, let button = memoryButton else { return }
        presentMemoryPopover(relativeTo: button)
    }

    // MARK: - Summarize (on-device, FoundationModels)

    /// Toolbar action. Availability is re-checked fresh on every invocation:
    /// `modelNotReady` self-heals, so a cached "unavailable" would be a lie.
    /// Vanish-cleanly law: unavailable → nothing visible happens, no error,
    /// no grey-out. Energy law: not `.normal` tier → quietly absent this
    /// moment (the memory-pressure input demotes the tier before this check).
    @objc func summarizeThisPage(_ sender: Any?) {
        switch SummarizeSession.availability() {
        case .available:
            break
        case .notReadyYet, .unavailable:
            return
        }
        guard (NSApp.delegate as? AppDelegate)?.inferenceAllowedNow() == true else {
            QwaveLog.summarize.info("summarize deferred: energy tier != normal")
            return
        }
        presentSummarizePopover()
    }

    private func presentSummarizePopover() {
        guard let button = summarizeButton else { return }
        if let popover = summarizePopover, popover.isShown {
            popover.close()
            summarizePopover = nil
            summarizeTask?.cancel()
            summarizeTask = nil
            return
        }
        summarizeTitle = tabManager.selectedTab?.displayTitle ?? ""
        summarizeBody = ""
        summarizeBusy = true
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: summarizePanelRoot())
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        summarizePopover = popover
        summarizeTask = Task { await runSummarize() }
    }

    private func runSummarize() async {
        guard let tab = tabManager.selectedTab else {
            summarizeBusy = false
            return
        }
        let webView = ensureWebView(for: tab)
        guard
            let json = await ArticleExtractor.extract(from: webView),
            let text = ArticleExtractor.text(from: json)
        else {
            summarizeBody = "Couldn't read the page."
            summarizeBusy = false
            refreshSummarizePopover()
            return
        }
        do {
            let result = try await SummarizeSession.summarize(text)
            guard !Task.isCancelled else { return }
            summarizeTitle = tab.displayTitle
            summarizeBody = result.text
            summarizeFootnote =
                result.refusalCount > 0
                ? "On-device · retried \(result.refusalCount)× · text never leaves this Mac."
                : "On-device · text never leaves this Mac."
            QwaveLog.summarize.info(
                "summarized \(text.count) chars in \(Int(result.totalMs)) ms (refusals: \(result.refusalCount))"
            )
        } catch let e as SummarizeError {
            guard !Task.isCancelled else { return }
            switch e {
            case .generationFailed(let refusals, let detail):
                // Refusal copy is radioactive: the real error goes to the log,
                // the neutral string to the panel.
                QwaveLog.summarize.warning(
                    "\(SummarizeUI.logLine(refusalCount: refusals, detail: detail))"
                )
            case .unavailable, .notReadyYet:
                QwaveLog.summarize.info("summarize unavailable: \(e)")
            case .extractionFailed, .deferredByEnergy:
                QwaveLog.summarize.info("summarize not run: \(e)")
            }
            summarizeBody = SummarizeUI.failureMessage
        } catch {
            guard !Task.isCancelled else { return }
            QwaveLog.summarize.error("summarize failed: \(String(describing: error))")
            summarizeBody = SummarizeUI.failureMessage
        }
        summarizeBusy = false
        refreshSummarizePopover()
    }

    private func cancelSummarize() {
        summarizeTask?.cancel()
        summarizeTask = nil
        summarizeBusy = false
        refreshSummarizePopover()
    }

    private func summarizePanelRoot() -> SummarizePanelView {
        SummarizePanelView(
            title: summarizeTitle,
            bodyText: summarizeBody,
            footnote: summarizeFootnote,
            isBusy: summarizeBusy,
            onCancel: { self.cancelSummarize() }
        )
    }

    private func refreshSummarizePopover() {
        guard let popover = summarizePopover, popover.isShown, let button = summarizeButton else { return }
        popover.contentViewController = NSHostingController(rootView: summarizePanelRoot())
        _ = button
    }

    /// Vanish-cleanly for the toolbar button: hidden unless the model is
    /// actually available. Called at window setup and on app foreground
    /// (modelNotReady self-heals, so the check must not be cached).
    func refreshSummarizePresence() {
        summarizeButton?.isHidden = SummarizeSession.availability() != .available
    }

    private func denialMessage(_ reason: MemoryWaveDenial) -> String {
        switch reason {
        case .notExplicit: return "Memory Wave only runs when you ask."
        case .ephemeral: return "Private and ephemeral tabs cannot write memories."
        case .energy: return "Inference is paused under thermal or memory pressure."
        case .providerDisabled: return "Choose a provider in Settings → Memory Wave."
        case .cognitiveEgress: return "Stored memories cannot leave this Mac."
        case .insecureEndpoint: return "Remote providers must use HTTPS."
        }
    }

    @objc func hibernateInactiveTabs(_ sender: Any?) {
        Task { @MainActor in
            for tab in tabManager.tabs where tab.id != tabManager.selectedTabID && tab.webView != nil {
                coordinators[tab.id]?.detach()
                await environment.hibernator.hibernate(tab)
            }
            render()
        }
    }

    @objc func toggleShields(_ sender: Any?) {
        guard let button = shieldsButton, let selected = tabManager.selectedTab,
            let host = selected.url.flatMap(CanonicalHost.host(of:))
        else {
            return
        }
        if let popover = shieldsPopover, popover.isShown {
            popover.close()
            shieldsPopover = nil
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: ShieldsPopoverView(
                host: host,
                policy: environment.shieldsPolicy,
                onChanged: { [weak self] in
                    guard let self, let tab = self.tabManager.selectedTab else { return }
                    tab.webView?.reload()
                    self.refreshChromeState()
                }
            )
        )
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        shieldsPopover = popover
    }

    /// Toolbar action: toggle the downloads popover anchored to its button.
    @objc func toggleDownloads(_ sender: Any?) {
        guard let button = downloadsButton else { return }
        if let popover = downloadsPopover, popover.isShown {
            popover.close()
            downloadsPopover = nil
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: DownloadsPopoverView(
                downloads: environment.downloads,
                onRetry: { [weak self] itemID in
                    guard let self, let webView = self.tabManager.selectedTab?.webView else { return }
                    self.environment.downloads.retry(itemID: itemID, using: webView)
                }
            )
        )
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        downloadsPopover = popover
    }

    /// Extensions toolbar action: popup of the first installed extension
    /// (a fuller extension manager lands with the MV3 engine milestones).
    @objc func toggleExtensions(_ sender: Any?) {
        guard let button = extensionsButton else { return }
        if let popup = extensionsPopup {
            popup.close()
            extensionsPopup = nil
            return
        }
        let router = environment.extensions.router
        let popup = ExtensionPopupController(router: router)
        extensionsPopup = popup
        router.tabQueryHandler = { [weak self] _ in
            guard let self, let tab = self.tabManager.selectedTab else { return [] }
            return [["id": 1, "url": tab.url?.absoluteString ?? "", "active": true, "title": tab.title ?? ""]]
        }
        router.tabCreateHandler = { [weak self] props in
            guard let self, let urlString = props["url"] as? String, let url = URL(string: urlString) else { return }
            self.openNewTab(url: url, activate: true)
        }
        if let ext = environment.extensions.extensions.first {
            popup.showPopup(for: ext, relativeTo: button, of: button.bounds)
        } else {
            let alert = NSAlert()
            alert.messageText = "No extensions installed"
            alert.informativeText =
                "Drop a WebExtension bundle directory (containing manifest.json) onto the Extensions button to install it."
            alert.beginSheetModal(for: window!)
        }
    }

    // MARK: - Handoff

    /// Keeps `browsingActivity` in step with the active tab. Suppressed contexts
    /// (private window, ephemeral tab, non-web URL) invalidate the activity so
    /// nothing private is ever advertised. `becomeCurrent()` is gated on key
    /// window so a background window finishing a load cannot steal Continuity
    /// from the window the user is actually looking at.
    private func updateHandoff(url: URL?, isEphemeralTab: Bool) {
        guard
            let handoffURL = HandoffPolicy.webpageURL(
                url: url, isPrivateWindow: isPrivate, isEphemeralTab: isEphemeralTab)
        else {
            browsingActivity?.invalidate()
            browsingActivity = nil
            return
        }
        let activity =
            browsingActivity
            ?? {
                let created = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
                created.isEligibleForHandoff = true
                browsingActivity = created
                return created
            }()
        if activity.webpageURL != handoffURL {
            activity.webpageURL = handoffURL
        }
        if window?.isKeyWindow == true {
            activity.becomeCurrent()
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        // Reclaim the app's current activity for the now-focused window.
        browsingActivity?.becomeCurrent()
    }

    func windowDidResignKey(_ notification: Notification) {
        // Stop advertising this window's page the moment focus leaves it, so
        // Continuity never keeps offering a superseded window's page after the
        // user moves to another window (which may have nothing to hand off).
        browsingActivity?.resignCurrent()
    }

    func windowWillClose(_ notification: Notification) {
        browsingActivity?.invalidate()
        browsingActivity = nil
        for tab in tabManager.tabs {
            teardown(tab: tab)
        }
        onWindowClosed?(self)
    }

    // MARK: - Toolbar construction helpers

    fileprivate func makeToolbarButton(symbol: String, label: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.isBordered = true
        button.setAccessibilityLabel(label)
        return button
    }

    fileprivate func configureOmnibox() -> OmniboxField {
        omnibox.placeholderString = "Search or enter address"
        omnibox.target = self
        omnibox.action = #selector(omniboxCommitted(_:))
        omnibox.bezelStyle = .roundedBezel
        omnibox.usesSingleLineMode = true
        omnibox.lineBreakMode = .byTruncatingTail
        omnibox.cell?.sendsActionOnEndEditing = false
        omnibox.font = .systemFont(ofSize: 13)
        omnibox.setAccessibilityLabel("Address and search")
        return omnibox
    }
}

// MARK: - Omnibox suggestions (NSTextFieldDelegate)

extension BrowserWindowController: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextField) === omnibox else { return }
        let query = omnibox.stringValue
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else {
            suggestionTask?.cancel()
            suggestionTask = nil
            suggestions.hide()
            return
        }
        // Debounce: cancel the prior in-flight query and wait out a short pause
        // so a burst of keystrokes runs the ranking work only once.
        suggestionTask?.cancel()
        suggestionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            // On-device sources first — these never leave the machine.
            let openTabs = self.tabManager.tabs.compactMap { tab -> OpenTabInfo? in
                guard tab.id != self.tabManager.selectedTabID, let url = tab.url else { return nil }
                return OpenTabInfo(id: tab.id, title: tab.displayTitle, url: url)
            }
            let entries = (try? await self.environment.history?.entries(matching: query, limit: 50)) ?? []
            let bookmarks = await self.environment.cachedBookmarks()
            // Network suggestions are strictly opt-in (default OFF). Only when
            // the user has enabled them do we send the query to a third party.
            let remote: [RemoteSearchSuggestion]
            if self.environment.settings.networkSuggestionsEnabled {
                remote = (try? await DuckDuckGoSuggestionProvider().fetchSuggestions(for: query)) ?? []
            } else {
                remote = []
            }
            let ranked = OmniboxSuggester.hybridSuggestions(
                for: query,
                history: entries,
                bookmarks: bookmarks,
                openTabs: openTabs,
                actions: OmniboxAction.defaults,
                remoteSuggestions: remote
            )
            guard self.omnibox.stringValue == query else { return }
            if ranked.isEmpty {
                self.suggestions.hide()
            } else {
                self.suggestions.show(ranked, below: self.omnibox)
            }
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard (notification.object as? NSTextField) === omnibox else { return }
        suggestions.hide()
    }

    /// Arrow keys and escape are handled here, in the omnibox's field editor
    /// — the panel never becomes key (focus stays in the field).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === omnibox, suggestions.isVisible else { return false }
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            suggestions.moveHighlight(by: 1)
            if let highlighted = suggestions.highlighted {
                omnibox.stringValue = highlighted.url.absoluteString
            }
            return true
        case #selector(NSResponder.moveUp(_:)):
            suggestions.moveHighlight(by: -1)
            if let highlighted = suggestions.highlighted {
                omnibox.stringValue = highlighted.url.absoluteString
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            suggestions.hide()
            return true
        default:
            return false
        }
    }
}

// MARK: - NSToolbarDelegate

extension BrowserWindowController: NSToolbarDelegate {
    private static let backItem = NSToolbarItem.Identifier("qwave.back")
    private static let forwardItem = NSToolbarItem.Identifier("qwave.forward")
    private static let reloadItem = NSToolbarItem.Identifier("qwave.reload")
    private static let omniboxItem = NSToolbarItem.Identifier("qwave.omnibox")
    private static let shieldsItem = NSToolbarItem.Identifier("qwave.shields")
    private static let memoryItem = NSToolbarItem.Identifier("qwave.memory")
    private static let summarizeItem = NSToolbarItem.Identifier("qwave.summarize")
    private static let downloadsItem = NSToolbarItem.Identifier("qwave.downloads")
    private static let extensionsItem = NSToolbarItem.Identifier("qwave.extensions")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Self.backItem, Self.forwardItem, Self.reloadItem, .flexibleSpace, Self.omniboxItem, .flexibleSpace,
            Self.memoryItem, Self.summarizeItem, Self.shieldsItem, Self.downloadsItem, Self.extensionsItem,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier {
        case Self.backItem:
            backButton = makeToolbarButton(symbol: "chevron.left", label: "Back", action: #selector(goBack(_:)))
            item.view = backButton
            item.label = "Back"
        case Self.forwardItem:
            forwardButton = makeToolbarButton(
                symbol: "chevron.right", label: "Forward", action: #selector(goForward(_:)))
            item.view = forwardButton
            item.label = "Forward"
        case Self.reloadItem:
            reloadButton = makeToolbarButton(symbol: "arrow.clockwise", label: "Reload", action: #selector(reload(_:)))
            item.view = reloadButton
            item.label = "Reload"
        case Self.omniboxItem:
            let field = configureOmnibox()
            item.view = field
            item.label = "Address"
            item.minSize = NSSize(width: 240, height: 24)
            item.maxSize = NSSize(width: 900, height: 24)
        case Self.memoryItem:
            memoryButton = makeToolbarButton(
                symbol: "waveform", label: "Memory Wave", action: #selector(toggleMemoryWave(_:)))
            item.view = memoryButton
            item.label = "Memory Wave"
        case Self.summarizeItem:
            summarizeButton = makeToolbarButton(
                symbol: "text.badge.star", label: "Summarize Page", action: #selector(summarizeThisPage(_:)))
            item.view = summarizeButton
            item.label = "Summarize Page"
        case Self.shieldsItem:
            shieldsButton = makeToolbarButton(
                symbol: "shield.fill", label: "Shields", action: #selector(toggleShields(_:)))
            item.view = shieldsButton
            item.label = "Shields"
        case Self.downloadsItem:
            downloadsButton = makeToolbarButton(
                symbol: "arrow.down.circle", label: "Downloads", action: #selector(toggleDownloads(_:)))
            item.view = downloadsButton
            item.label = "Downloads"
        case Self.extensionsItem:
            extensionsButton = makeToolbarButton(
                symbol: "puzzlepiece.extension", label: "Extensions", action: #selector(toggleExtensions(_:)))
            item.view = extensionsButton
            item.label = "Extensions"
        default:
            return nil
        }
        return item
    }
}
