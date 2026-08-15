import AppKit
import BrowserCore
import Shields
import FeatureFlags
import Persistence
import VPNKit
import WebExtensions
import MemoryWave
import QwaveSupport
import AppleMusicKit

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
    /// Apple Music "now playing" HUD backend. One instance, shared across
    /// windows — it observes the single system music player, not a per-tab
    /// or per-window state. See docs/MUSIC.md.
    let appleMusic = AppleMusicSession()

    private let directory: URL
    private var startPageMemories: [StartMemoryChip] = []
    private var timelineDays: [TimelineDayView] = []
    /// Cached full bookmark set, shared across omnibox keystrokes so the store
    /// is queried once rather than on every character. Invalidated whenever a
    /// bookmark is added or removed (see `invalidateBookmarkCache`).
    private var bookmarkCache: [Bookmark]?
    /// Bumped on every invalidation so a load that suspended across a mutation
    /// does not write its stale result back into the cache (see cachedBookmarks).
    private var bookmarkGeneration = 0

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
        // Memory Wave is optional, but a nil store must not silently read as
        // "no memories". A malformed master key means the records are still on
        // disk and still sealed, and the key is left untouched rather than
        // regenerated, so that case is logged distinctly from every other one.
        //
        // The store and the nibble vault share one master key, derived once
        // here, so a locked key locks both paths together instead of the
        // vault falling back to its own key (or, pre-#81, to no encryption at
        // all) while the database stays locked.
        let memoryStore: MemoryStore?
        var nibbleVault: NibbleVault?
        do {
            let key = try MemoryCipher.loadOrCreateKey(in: secrets)
            memoryStore = try MemoryStore(directory: directory, key: key)
            nibbleVault = try? NibbleVault(
                directory: directory.appendingPathComponent("nibbles", isDirectory: true), key: key)
        } catch MemoryCipherError.malformedKey {
            memoryStore = nil
            nibbleVault = nil
            QwaveLog.memory.error(
                "Memory Wave locked: stored master key is malformed; memories are sealed, not lost")
        } catch SecretStoreError.duplicateItem {
            memoryStore = nil
            nibbleVault = nil
            QwaveLog.memory.error(
                "Memory Wave locked: a master key exists but could not be read back; not re-keyed")
        } catch {
            memoryStore = nil
            nibbleVault = nil
            QwaveLog.memory.error("Memory Wave unavailable: \(error)")
        }
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

    /// The full bookmark set, loaded once and reused. Content is identical to
    /// `bookmarks?.all()`; only the query frequency changes.
    func cachedBookmarks() async -> [Bookmark] {
        if let bookmarkCache { return bookmarkCache }
        let generation = bookmarkGeneration
        let all = (try? await bookmarks?.all()) ?? []
        // Only cache if no add/remove invalidated us during the await; otherwise
        // return this (now-stale) read but leave the cache empty so the next
        // call reloads fresh, instead of poisoning it.
        if bookmarkGeneration == generation {
            bookmarkCache = all
        }
        return all
    }

    /// Drops the cached bookmark set so the next read reloads from the store.
    /// Call after any bookmark add/remove.
    func invalidateBookmarkCache() {
        bookmarkCache = nil
        bookmarkGeneration &+= 1
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
        let tagChips = await memoryWave.nibbleTags(limit: 10).map {
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
        // Read-only status check — MusicAuthorization.currentStatus, not a
        // request — so this never surfaces a permission prompt on launch.
        await environment.appleMusic.refreshAvailability()
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
