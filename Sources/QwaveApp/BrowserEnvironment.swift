import AppKit
import BrowserCore
import Shields
import FeatureFlags
import Persistence
import VPNKit
import WebExtensions
import MemoryWave
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
    /// MEM8 wave memory. Optional — the browser runs without it.
    let memoryWave: WaveDirector
    let memoryPreferences: MemoryWavePreferences
    let secrets: SecretStore

    private let directory: URL

    private init(directory: URL) {
        self.directory = directory
        settings = SettingsStore()
        secrets = KeychainSecretStore()
        memoryPreferences = MemoryWavePreferences(secrets: secrets)
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
        vpn = MullvadVPNService(secrets: secrets)
        extensions = WebExtensionHost(storageDirectory: directory)
        let memoryStore = try? MemoryStore(directory: directory, secrets: secrets)
        memoryWave = WaveDirector(store: memoryStore, preferences: memoryPreferences)
        // EasyList mirror + Qwave's own curated list; ETag-cached, no-op
        // fallback keeps the director simple.
        blocklistUpdater = RemoteBlocklistUpdater(
            sourceURL: URL(string: "https://raw.githubusercontent.com/easylist/easylist/master/easylist/easylist.txt")!
        )

        // Defaults sync: shields policy mirrors settings toggles.
        shieldsPolicy.defaultAdsBlocked = settings.shieldsEnabledByDefault
        shieldsPolicy.defaultHTTPSFirst = settings.httpsFirstEnabled

        QwaveInternal.startPageHTML = { [weak self] in
            guard let self else {
                return InternalPages.startHTML(memories: [], providerLabel: "Remember only")
            }
            let records = (try? self.memoryWave.recall(containerID: nil, limit: 8)) ?? []
            let chips = records.map {
                StartMemoryChip(title: $0.title, preview: String($0.body.prefix(96)))
            }
            let label: String
            switch self.memoryPreferences.providerKind {
            case .none: label = "Remember only"
            case .onDevice: label = "On-device"
            case .openaiCompatible: label = "OpenAI-compatible"
            }
            return InternalPages.startHTML(memories: chips, providerLabel: label)
        }
    }

    static func bootstrap() -> BrowserEnvironment {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
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
