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
    let favicons: FaviconStore?
    let sessionStore: SessionStore?
    let downloads: DownloadManager
    let httpsUpgrader: HTTPSFirstUpgrader
    let factory: WebViewFactory
    let hibernator: TabHibernator
    let hibernation: HibernationController
    let vpn: MullvadVPNService
    /// WebExtensions MV3 engine (browser.* bridge, popups, storage).
    let extensions: WebExtensionHost
    /// MEM8 wave memory. Optional — the browser runs without it.
    let memoryWave: WaveDirector
    let memoryPreferences: MemoryWavePreferences
    let secrets: SecretStore

    private let directory: URL
    private var startPageMemories: [StartMemoryChip] = []
    private var timelineDays: [TimelineDayView] = []

    private init(directory: URL) async {
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

        if let database = try? SQLiteDatabase(url: directory.appendingPathComponent("browser.db")) {
            history = try? await HistoryStore(database: database)
            bookmarks = try? await BookmarkStore(database: database)
            favicons = try? await FaviconStore(database: database)
        } else {
            history = nil
            bookmarks = nil
            favicons = nil
        }
        sessionStore = try? await SessionStore(directory: directory)

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
        let nibbleVault = try? NibbleVault(directory: directory.appendingPathComponent("nibbles", isDirectory: true))
        memoryWave = WaveDirector(store: memoryStore, preferences: memoryPreferences, vault: nibbleVault)
        // The blocklist ships as a committed build-time snapshot (regenerated
        // by scripts/update-blocklist.sh); there is no launch-time fetch, so
        // the app makes no network request at startup. RemoteBlocklistUpdater
        // remains available (and tested) for a future opt-in runtime path.

        // Defaults sync: shields policy mirrors settings toggles.
        shieldsPolicy.defaultAdsBlocked = settings.shieldsEnabledByDefault
        shieldsPolicy.defaultHTTPSFirst = settings.httpsFirstEnabled

        QwaveInternal.startPageHTML = { [weak self] in
            self?.makeStartPageHTML()
                ?? InternalPages.startHTML(memories: [], providerLabel: "Remember only")
        }
        QwaveInternal.timelinePageHTML = { [weak self] in
            self?.makeTimelinePageHTML()
                ?? InternalPages.timelineHTML(
                    days: [],
                    summary: QwaveInternal.lastTimelineSummary.isEmpty ? nil : QwaveInternal.lastTimelineSummary,
                    rememberEverything: false, providerLabel: "Remember only")
        }
    }

    var providerLabel: String {
        switch memoryPreferences.providerKind {
        case .none: return "Remember only"
        case .onDevice: return "On-device"
        case .openaiCompatible: return "OpenAI-compatible"
        }
    }

    func makeStartPageHTML() -> String {
        return InternalPages.startHTML(
            memories: startPageMemories,
            providerLabel: providerLabel,
            rememberEverything: memoryPreferences.rememberEverything
        )
    }

    func makeTimelinePageHTML() -> String {
        InternalPages.timelineHTML(
            days: timelineDays,
            summary: QwaveInternal.lastTimelineSummary.isEmpty ? nil : QwaveInternal.lastTimelineSummary,
            rememberEverything: memoryPreferences.rememberEverything,
            providerLabel: providerLabel
        )
    }

    func refreshInternalPages() async {
        let tagChips = memoryWave.nibbleTags(limit: 10).map {
            StartMemoryChip(title: "#\($0)", preview: "nibble")
        }
        let records = (try? await memoryWave.recall(containerID: nil, limit: 8)) ?? []
        let recordChips = records.map {
            StartMemoryChip(title: $0.title, preview: String($0.body.prefix(96)))
        }
        startPageMemories = tagChips + recordChips
        timelineDays = ((try? await memoryWave.timeline(range: .all)) ?? []).map { day in
            TimelineDayView(
                heading: day.heading,
                items: day.items.prefix(24).map { item in
                    let time = item.created.formatted(date: .omitted, time: .shortened)
                    let host = item.url?.host ?? item.kind.rawValue
                    let tags = item.tags.prefix(4).map { "#\($0)" }.joined(separator: " ")
                    let detail = tags.isEmpty ? "\(time) · \(host)" : "\(time) · \(host) · \(tags)"
                    return TimelineItemView(
                        title: item.title,
                        detail: detail,
                        href: item.url?.absoluteString
                    )
                }
            )
        }
    }

    /// The on-disk home for all app state (containers.json, shields.json, the
    /// SQLite db, …). Exposed so out-of-band callers such as App Intent queries
    /// can read persisted state (e.g. containers) without the running graph.
    static var supportDirectory: URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Qwave", isDirectory: true)
    }

    static func bootstrap() async -> BrowserEnvironment {
        let directory = supportDirectory
        let environment = await BrowserEnvironment(directory: directory)
        await environment.refreshInternalPages()
        return environment
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
