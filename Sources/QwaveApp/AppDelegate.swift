import AppKit
import BrowserCore
import Persistence
import QwaveSupport
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private(set) var environment: BrowserEnvironment!
    private var windowControllers: [BrowserWindowController] = []
    private var settingsWindowController: SettingsWindowController?
    private var libraryWindowController: LibraryWindowController?
    private var vpnStatusItem: VPNStatusItem?
    /// Sparkle auto-updater; feed and EdDSA public key come from Info.plist
    /// (SUFeedURL / SUPublicEDKey, declared in project.yml).
    private(set) var updaterController: SPUStandardUpdaterController?

    /// Single coalesced timer driving hibernation + energy management for the
    /// whole app — one wakeup, generous leeway, instead of per-tab timers.
    private var energyTimer: DispatchSourceTimer?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var underMemoryPressure = false

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        let updater = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        updaterController = updater
        NSApp.mainMenu = MainMenu.build(updater: updater)
        startMemoryPressureSource()
        startEnergyObservers()
        Task {
            environment = await BrowserEnvironment.bootstrap()
            vpnStatusItem = VPNStatusItem(vpn: environment.vpn)
            // Start the rule-list compile and VPN refresh now, but do NOT block
            // the first window on them: the window + local start page paint
            // immediately (that is where the perceived-launch win lives), and the
            // first NETWORK navigation gates on shields.whenReady() inside
            // NavigationCoordinator — so shields are never bypassed. See issue #19.
            async let shieldsPrepared: Void = environment.shields.prepare()
            async let vpnRefreshed: Void = environment.vpn.tunnel.refresh()
            await restoreOrOpenFirstWindow()
            startEnergyTimer()
            // Do not abandon the concurrent warmups (an unawaited async let is
            // cancelled at scope end); the gate already made them non-blocking.
            await shieldsPrepared
            await vpnRefreshed
        }
        // No launch-time network egress: the blocklist ships as a committed
        // build-time snapshot (scripts/update-blocklist.sh + commit), so
        // shields are fully active from a cold start with zero requests. The
        // former launch fetch discarded its result anyway — egress that
        // bought the user nothing. See docs/NETWORK.md and docs/BLOCKLIST.md.

        QwaveLog.browser.info("Qwave launched")
    }

    /// Notification-driven energy reactions: thermal-state, low-power-mode
    /// and window-occlusion changes apply the governor's new tier within
    /// milliseconds instead of at the next 30 s tick (leeway 10 s).
    /// Occlusion storms while stacking windows are coalesced by the
    /// interval gate; the 30 s timer remains the steady cadence.
    private var energyObservers: [NSObjectProtocol] = []
    private var lastNotificationEnergyTick = Date.distantPast
    private let energyNotificationMinInterval: TimeInterval = 5

    private func startEnergyObservers() {
        func observe(_ name: Notification.Name) {
            energyObservers.append(
                NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        await self?.energyTickFromNotification()
                    }
                }
            )
        }
        observe(ProcessInfo.thermalStateDidChangeNotification)
        observe(NSNotification.Name.NSProcessInfoPowerStateDidChange)
        observe(NSWindow.didChangeOcclusionStateNotification)
    }

    private func energyTickFromNotification() async {
        // The environment is built asynchronously after launch; the first
        // notifications can arrive before it exists.
        guard environment != nil else { return }
        let now = Date()
        guard now.timeIntervalSince(lastNotificationEnergyTick) >= energyNotificationMinInterval
        else { return }
        lastNotificationEnergyTick = now
        await energyTick()
    }

    private func restoreOrOpenFirstWindow() async {
        if environment.settings.restoreSessionOnLaunch,
            let snapshot = await environment.sessionStore?.load(),
            !snapshot.windows.isEmpty
        {
            for manager in SessionRestorer.managers(from: snapshot) {
                openWindow(tabManager: manager)
            }
        } else {
            openWindow()
        }
    }

    // MARK: - Windows

    @discardableResult
    func openWindow(tabManager: TabManager? = nil, isPrivate: Bool = false) -> BrowserWindowController {
        let controller = BrowserWindowController(environment: environment, tabManager: tabManager, isPrivate: isPrivate)
        controller.onWindowClosed = { [weak self] closed in
            self?.windowControllers.removeAll { $0 === closed }
        }
        windowControllers.append(controller)
        controller.showWindow(nil)
        return controller
    }

    var frontmostBrowserWindow: BrowserWindowController? {
        (NSApp.keyWindow?.windowController as? BrowserWindowController) ?? windowControllers.last
    }

    /// Opens a URL in the frontmost window (used by Library, status item, etc.)
    func openInFrontmostWindow(url: URL) {
        let controller = frontmostBrowserWindow ?? openWindow()
        controller.openNewTab(url: url, activate: true)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    @objc func newWindow(_ sender: Any?) {
        openWindow()
    }

    /// Every tab ephemeral, excluded from session restore (all-ephemeral
    /// windows produce no snapshot), no frame autosave.
    @objc func newPrivateWindow(_ sender: Any?) {
        openWindow(isPrivate: true)
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                environment: environment, updater: updaterController?.updater)
        }
        settingsWindowController?.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showLibrary(_ sender: Any?) {
        if libraryWindowController == nil {
            libraryWindowController = LibraryWindowController(environment: environment) { [weak self] url in
                self?.openInFrontmostWindow(url: url)
            }
        }
        libraryWindowController?.showWindow(sender)
    }

    // MARK: - Default browser

    /// True when Qwave is the current http handler — the scheme macOS keys the
    /// default-browser designation on (https resolves to the same app).
    static func isDefaultBrowser() -> Bool {
        guard let probe = URL(string: "http://example.com"),
            let handler = NSWorkspace.shared.urlForApplication(toOpen: probe),
            let bundle = Bundle(url: handler)
        else { return false }
        return bundle.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    /// Asks macOS to make Qwave the default browser. The system presents its own
    /// confirmation before switching — this only requests it. No entitlement is
    /// required on macOS; the http/https CFBundleURLTypes declaration
    /// (project.yml) is what makes Qwave an eligible handler.
    @objc func makeDefaultBrowser(_ sender: Any?) {
        let appURL = Bundle.main.bundleURL
        Task {
            do {
                // macOS keys the default-browser role on the http scheme; set
                // https too so scheme-typed links also resolve to Qwave. Setting
                // is per-scheme, so if the user declines the first consent
                // prompt, stop rather than immediately prompting again.
                try await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: "http")
                try await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: "https")
            } catch {
                QwaveLog.browser.error("Failed to set Qwave as default browser: \(error.localizedDescription)")
            }
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(makeDefaultBrowser(_:)) {
            let isDefault = Self.isDefaultBrowser()
            menuItem.title = isDefault ? "Qwave Is the Default Browser" : "Set Qwave as Default Browser…"
            return !isDefault
        }
        return true
    }

    // MARK: - Termination

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        energyTimer?.cancel()
        for observer in energyObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { [weak self] in
            await self?.saveSession()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            openWindow()
        }
        return true
    }

    private func saveSession() async {
        guard let store = environment.sessionStore else { return }
        let managers = windowControllers.map(\.tabManager)
        let snapshot = SessionRestorer.snapshot(of: managers)
        try? await store.save(snapshot)
    }

    // MARK: - Energy management

    private func startEnergyTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // 30s cadence with 10s leeway: the system coalesces our wakeup with
        // others, which is the whole point.
        timer.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(10))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor [weak self] in
                await self?.energyTick()
            }
        }
        timer.resume()
        energyTimer = timer
    }

    private func currentConditions() -> EnergyConditions {
        let occluded = windowControllers.allSatisfy { controller in
            guard let window = controller.window else { return true }
            return !window.occlusionState.contains(.visible)
        }
        return EnergyConditions(
            thermalState: ProcessInfo.processInfo.thermalState,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            allWindowsOccluded: !windowControllers.isEmpty && occluded,
            underMemoryPressure: underMemoryPressure
        )
    }

    private func startMemoryPressureSource() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = source.data
            self.underMemoryPressure = event.contains(.warning) || event.contains(.critical)
        }
        source.resume()
        memoryPressureSource = source
    }

    func inferenceAllowedNow() -> Bool {
        EnergyGovernor.tier(for: currentConditions()) == .normal
    }

    private func energyTick() async {
        // P0 instrumentation: the whole tick runs on the main actor, so an
        // Instruments Points-of-Interest capture during Speedometer shows
        // exactly when (and for how long) it stalls the foreground. See docs/PERF.md.
        let signpostID = QwaveSignposts.energy.makeSignpostID()
        let interval = QwaveSignposts.energy.beginInterval("energy-tick", id: signpostID)
        defer { QwaveSignposts.energy.endInterval("energy-tick", interval) }

        let policy = EnergyGovernor.policy(
            for: currentConditions(),
            baseHibernationTimeout: environment.settings.hibernationTimeout
        )
        environment.hibernation.updateTimeout(policy.hibernationTimeout)

        for controller in windowControllers {
            await controller.applyEnergyPolicy(
                policy, hibernation: environment.hibernation, hibernator: environment.hibernator)
        }
    }
}
