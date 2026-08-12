import AppKit
import BrowserCore
import Shields
import FeatureFlags
import Persistence
import VPNKit
import WebExtensions
import QwaveSupport

/// The app-wide service graph, built once at launch.
@MainActor
final class BrowserEnvironment {
    let settings: SettingsStore
    let containers: ContainerRegistry
    let shieldsPolicy: ShieldsPolicy
    let shields: ShieldsDirector
    let featureFlags: FeatureFlagService
    let history: HistoryStore?
    let bookmarks: BookmarkStore?
    let sessionStore: SessionStore?
    let downloads: DownloadManager
    let httpsUpgrader: HTTPSFirstUpgrader
    let factory: WebViewFactory
    let hibernator: TabHibernator
    let hibernation: HibernationController
    let vpn: MullvadVPNService
    /// WebExtensions MV3 engine (browser.* bridge, popups, storage).
    let extensions: WebExtensionHost
    /// Remote uBlock/EasyList blocklist updater (ETag-cached).
    let blocklistUpdater: BlocklistUpdating

    private let directory: URL

    private init(directory: URL) {
        self.directory = directory
        settings = SettingsStore()
        containers = ContainerRegistry(directory: directory)
        shieldsPolicy = ShieldsPolicy(directory: directory)
        shields = ShieldsDirector(compiler: RuleListCompiler(), policy: shieldsPolicy)
        featureFlags = FeatureFlagService()
        httpsUpgrader = HTTPSFirstUpgrader()
        downloads = DownloadManager()

        let database = try? SQLiteDatabase(url: directory.appendingPathComponent("browser.db"))
        history = database.flatMap { try? HistoryStore(database: $0) }
        bookmarks = database.flatMap { try? BookmarkStore(database: $0) }
        sessionStore = try? SessionStore(directory: directory)

        factory = WebViewFactory(
            containers: containers,
            shields: shields,
            featureFlags: featureFlags,
            settings: settings
        )
        hibernator = TabHibernator(factory: factory)
        hibernation = HibernationController(timeout: settings.hibernationTimeout)
        vpn = MullvadVPNService(secrets: KeychainSecretStore())
        extensions = WebExtensionHost(storageDirectory: directory)
        // EasyList mirror + Qwave's own curated list; ETag-cached, no-op
        // fallback keeps the director simple.
        blocklistUpdater = RemoteBlocklistUpdater(
            sourceURL: URL(string: "https://raw.githubusercontent.com/easylist/easylist/master/easylist/easylist.txt")!
        )

        // Defaults sync: shields policy mirrors settings toggles.
        shieldsPolicy.defaultAdsBlocked = settings.shieldsEnabledByDefault
        shieldsPolicy.defaultHTTPSFirst = settings.httpsFirstEnabled
    }

    static func bootstrap() -> BrowserEnvironment {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("Qwave", isDirectory: true)
        return BrowserEnvironment(directory: directory)
    }

    /// Builds a coordinator wired to this environment for one tab.
    func makeCoordinator(for tab: Tab) -> NavigationCoordinator {
        NavigationCoordinator(
            tab: tab,
            shields: shields,
            httpsUpgrader: httpsUpgrader,
            history: tab.isEphemeral ? nil : history,
            downloads: downloads
        )
    }
}
