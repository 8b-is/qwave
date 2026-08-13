import AppKit
import BrowserCore
import Persistence
import QwaveSupport
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
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
        environment = BrowserEnvironment.bootstrap()
        let updater = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        updaterController = updater
        NSApp.mainMenu = MainMenu.build(updater: updater)
        vpnStatusItem = VPNStatusItem(vpn: environment.vpn)

        Task { @MainActor in
            await environment.shields.prepare()
            await environment.vpn.tunnel.refresh()
            restoreOrOpenFirstWindow()
        }
        // No launch-time network egress: the blocklist ships as a committed
        // build-time snapshot (scripts/update-blocklist.sh + commit), so
        // shields are fully active from a cold start with zero requests. The
        // former launch fetch discarded its result anyway — egress that
        // bought the user nothing. See docs/NETWORK.md and docs/BLOCKLIST.md.

        startEnergyTimer()
        startMemoryPressureSource()
        QwaveLog.browser.info("Qwave launched")
    }

    private func restoreOrOpenFirstWindow() {
        if environment.settings.restoreSessionOnLaunch,
            let snapshot = environment.sessionStore?.load(),
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
            settingsWindowController = SettingsWindowController(environment: environment)
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

    // MARK: - Termination

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveSession()
        energyTimer?.cancel()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            openWindow()
        }
        return true
    }

    private func saveSession() {
        guard let store = environment.sessionStore else { return }
        let managers = windowControllers.map(\.tabManager)
        let snapshot = SessionRestorer.snapshot(of: managers)
        try? store.save(snapshot)
    }

    // MARK: - Energy management

    private func startEnergyTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // 30s cadence with 10s leeway: the system coalesces our wakeup with
        // others, which is the whole point.
        timer.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(10))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.energyTick()
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
