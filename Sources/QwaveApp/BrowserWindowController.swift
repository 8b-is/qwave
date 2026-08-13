import AppKit
import WebKit
import BrowserCore
import Shields
import WebExtensions
import SwiftUI
import URLIdentity

/// One browser window: toolbar (navigation + omnibox + shields), tab strip,
/// and the web view container. Owns a `TabManager` and per-tab coordinators.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    let environment: BrowserEnvironment
    let tabManager: TabManager

    var onWindowClosed: ((BrowserWindowController) -> Void)?

    private let tabBar = TabBarView()
    private let containerView = WebViewContainerView()
    private let findBar = FindBarView()
    private let findController = FindInPageController()
    private let omnibox = OmniboxField()

    private var backButton: NSButton!
    private var forwardButton: NSButton!
    private var reloadButton: NSButton!
    private var shieldsButton: NSButton!
    private var extensionsButton: NSButton!

    private var coordinators: [UUID: NavigationCoordinator] = [:]
    private var shieldsPopover: NSPopover?
    private var extensionsPopup: ExtensionPopupController?

    // MARK: - Init

    init(environment: BrowserEnvironment, tabManager: TabManager? = nil) {
        self.environment = environment
        self.tabManager = tabManager ?? TabManager()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.tabbingMode = .disallowed
        window.center()
        window.setFrameAutosaveName("QwaveBrowserWindow")
        super.init(window: window)

        window.delegate = self
        setupToolbar()
        setupTabBarAccessory()
        setupContent()
        wireTabManager()
        wireTabBar()
        wireFindBar()

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
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            findBar.heightAnchor.constraint(equalToConstant: 30),
            findBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            containerView.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func wireTabManager() {
        tabManager.onChange = { [weak self] in
            self?.render()
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

    private func appendFreshTab(activate: Bool) {
        let tab = Tab()
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
        let tab = Tab(
            containerID: ephemeral ? ContainerRegistry.ephemeralProfileID : containerID,
            isEphemeral: ephemeral,
            pendingURL: url
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
            self?.refreshChromeState()
        }
        coordinator.attach(to: webView)

        if let state = record?.interactionState {
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

    private func render() {
        if tabManager.isEmpty {
            appendFreshTab(activate: true)
            return
        }

        let models = tabManager.tabs.map { tab in
            TabDisplayModel(
                id: tab.id,
                title: tab.displayTitle,
                isPinned: tab.isPinned,
                isHibernated: tab.isHibernated,
                isLoading: tab.isLoading,
                isEphemeral: tab.isEphemeral,
                containerColorHex: environment.containers.profile(withID: tab.containerID)?.colorHex
            )
        }
        tabBar.update(tabs: models, selectedID: tabManager.selectedTabID)

        if let selected = tabManager.selectedTab {
            let webView = ensureWebView(for: selected)
            containerView.show(webView)
        }
        refreshChromeState()
    }

    private func refreshChromeState() {
        guard let selected = tabManager.selectedTab else { return }
        let webView = selected.webView

        window?.title = selected.displayTitle
        backButton?.isEnabled = webView?.canGoBack ?? false
        forwardButton?.isEnabled = webView?.canGoForward ?? false

        let isEditingOmnibox = window?.firstResponder is NSTextView
            && omnibox.currentEditor() === (window?.firstResponder as? NSTextView)
        if !isEditingOmnibox {
            omnibox.stringValue = selected.url?.absoluteString ?? ""
        }

        if let button = reloadButton {
            let symbol = selected.isLoading ? "xmark" : "arrow.clockwise"
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: selected.isLoading ? "Stop" : "Reload")
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
        let models = tabManager.tabs.map { tab in
            TabDisplayModel(
                id: tab.id,
                title: tab.displayTitle,
                isPinned: tab.isPinned,
                isHibernated: tab.isHibernated,
                isLoading: tab.isLoading,
                isEphemeral: tab.isEphemeral,
                containerColorHex: environment.containers.profile(withID: tab.containerID)?.colorHex
            )
        }
        tabBar.update(tabs: models, selectedID: tabManager.selectedTabID)
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
        var infos: [TabHibernationInfo] = []
        for tab in tabManager.tabs {
            let isSelected = tab.id == tabManager.selectedTabID
            var isPlaying = false
            if let webView = tab.webView {
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
                    lastActivated: tab.lastActivated
                )
            )
        }

        let victims = hibernation.tabsToHibernate(now: Date(), tabs: infos)
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
        try? environment.bookmarks?.add(title: selected.displayTitle, url: url)
    }

    @objc func selectNextTab(_ sender: Any?) { tabManager.selectNext() }
    @objc func selectPreviousTab(_ sender: Any?) { tabManager.selectPrevious() }

    @objc func togglePinTab(_ sender: Any?) {
        guard let selected = tabManager.selectedTab else { return }
        selected.isPinned.toggle()
        render()
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
              let host = selected.url.flatMap(CanonicalHost.host(of:)) else {
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
            alert.informativeText = "Drop a WebExtension bundle directory (containing manifest.json) onto the Extensions button to install it."
            alert.beginSheetModal(for: window!)
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
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
        return omnibox
    }
}

// MARK: - NSToolbarDelegate

extension BrowserWindowController: NSToolbarDelegate {
    private static let backItem = NSToolbarItem.Identifier("qwave.back")
    private static let forwardItem = NSToolbarItem.Identifier("qwave.forward")
    private static let reloadItem = NSToolbarItem.Identifier("qwave.reload")
    private static let omniboxItem = NSToolbarItem.Identifier("qwave.omnibox")
    private static let shieldsItem = NSToolbarItem.Identifier("qwave.shields")
    private static let extensionsItem = NSToolbarItem.Identifier("qwave.extensions")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.backItem, Self.forwardItem, Self.reloadItem, .flexibleSpace, Self.omniboxItem, .flexibleSpace, Self.shieldsItem, Self.extensionsItem]
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
            forwardButton = makeToolbarButton(symbol: "chevron.right", label: "Forward", action: #selector(goForward(_:)))
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
        case Self.shieldsItem:
            shieldsButton = makeToolbarButton(symbol: "shield.fill", label: "Shields", action: #selector(toggleShields(_:)))
            item.view = shieldsButton
            item.label = "Shields"
        case Self.extensionsItem:
            extensionsButton = makeToolbarButton(symbol: "puzzlepiece.extension", label: "Extensions", action: #selector(toggleExtensions(_:)))
            item.view = extensionsButton
            item.label = "Extensions"
        default:
            return nil
        }
        return item
    }
}
