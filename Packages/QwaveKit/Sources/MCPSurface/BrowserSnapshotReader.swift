import Foundation
import Persistence

// MARK: - Wire types
//
// These are what leaves the process. They are deliberately narrower than the
// Persistence types they are built from:
//
// * no `containerID` — a container UUID correlates rows across Qwave's
//   container isolation, which is the one thing that isolation exists to
//   prevent; nothing here needs it.
// * no `interactionState` — the session file stores WebKit's opaque
//   interaction state per tab, which carries the full back/forward list, scroll
//   offsets **and form field contents** (SessionStore.swift:9-12). It is never
//   read here and never encoded.
// * nothing at all from MemoryWave. This target does not depend on it.

public struct HistoryItem: Codable, Sendable, Equatable {
    public let url: String
    public let title: String
    public let visitCount: Int
    public let lastVisit: Date

    public init(url: String, title: String, visitCount: Int, lastVisit: Date) {
        self.url = url
        self.title = title
        self.visitCount = visitCount
        self.lastVisit = lastVisit
    }
}

public struct BookmarkItem: Codable, Sendable, Equatable {
    public let title: String
    public let url: String
    public let folder: String?
    public let created: Date

    public init(title: String, url: String, folder: String?, created: Date) {
        self.title = title
        self.url = url
        self.folder = folder
        self.created = created
    }
}

public struct SavedTabItem: Codable, Sendable, Equatable {
    public let url: String?
    public let title: String
    public let isPinned: Bool

    public init(url: String?, title: String, isPinned: Bool) {
        self.url = url
        self.title = title
        self.isPinned = isPinned
    }
}

public struct SavedWindowItem: Codable, Sendable, Equatable {
    public let selectedIndex: Int
    public let tabs: [SavedTabItem]

    public init(selectedIndex: Int, tabs: [SavedTabItem]) {
        self.selectedIndex = selectedIndex
        self.tabs = tabs
    }
}

/// The last *saved* session, with everything a caller needs in order to know
/// how much to trust it. Named for what it is: this is not the live tab set,
/// and the payload says so rather than leaving the caller to assume.
public struct SavedSessionReport: Codable, Sendable, Equatable {
    public let savedAt: Date
    /// Seconds between `savedAt` and the moment this report was produced.
    public let ageSeconds: Int
    public let windows: [SavedWindowItem]
    /// The caveats that apply to every field above, restated in the payload
    /// because a tool description is not carried alongside the result.
    public let caveats: [String]

    public static let standardCaveats = [
        "This is the last autosaved snapshot, not the browser's live tab set.",
        "Saves are debounced ~2s after activity and forced at most every 30s, so a very recent navigation may be missing.",
        "A snapshot with zero persistable windows is never written, so after the last window closes this file keeps describing tabs that are no longer open.",
        "Private and ephemeral tabs are excluded and never appear here.",
    ]

    public init(savedAt: Date, ageSeconds: Int, windows: [SavedWindowItem], caveats: [String] = standardCaveats) {
        self.savedAt = savedAt
        self.ageSeconds = ageSeconds
        self.windows = windows
        self.caveats = caveats
    }
}

// MARK: - Reader

public enum BrowserSnapshotError: Error, Sendable, Equatable {
    /// `browser.db` is not on disk. Reported rather than papered over: opening
    /// it would *create* an empty database, and every tool would then answer
    /// "no history" — which is a different claim from "no profile here".
    case databaseMissing(path: String)
    /// `session.json` has never been written (or was cleared).
    case sessionSnapshotMissing(path: String)
    case sessionSnapshotUnreadable(path: String)
}

/// Reads the three things a separate process can actually see: the history
/// table, the bookmarks table, and the autosaved session file.
///
/// The SQLite stores are reached through `HistoryStore` / `BookmarkStore` —
/// the very actors the browser writes through — rather than through hand-rolled
/// SELECTs, so the rows this surface reports cannot drift away from the rows
/// the browser has. Concurrent access is safe: `SQLiteDatabase` opens in WAL
/// mode with a 5s busy timeout (SQLiteDatabase.swift:84-89), so a reader in
/// another process gets a consistent committed snapshot without blocking the
/// browser's writer and without being blocked by it.
///
/// One honest caveat on "read-only": `SQLiteDatabase(url:)` opens
/// `SQLITE_OPEN_READWRITE`, and `HistoryStore.init` runs its schema migration.
/// Against a database the browser has already migrated that is a
/// `PRAGMA user_version` read and nothing else; against a stale one it would
/// apply `CREATE TABLE IF NOT EXISTS`. Every *query* below is a SELECT and
/// there is no code path here that inserts, updates or deletes. A kernel-
/// enforced `SQLITE_OPEN_READONLY` handle would be tidier, but it would mean
/// hand-writing the SELECTs instead of reusing the browser's own stores — and
/// duplicated SQL is precisely how a reporting surface drifts into lying about
/// what the browser holds. It would also buy no security: anyone who can spawn
/// this binary can already open `browser.db` themselves.
public actor BrowserSnapshotReader {
    private let location: QwaveProfileLocation
    private let now: @Sendable () -> Date
    private var database: SQLiteDatabase?
    private var history: HistoryStore?
    private var bookmarks: BookmarkStore?

    public init(location: QwaveProfileLocation = .default, now: @escaping @Sendable () -> Date = Date.init) {
        self.location = location
        self.now = now
    }

    // MARK: History

    public func recentHistory(limit: Int) async throws -> [HistoryItem] {
        try await openHistory().entries(limit: limit).map(Self.item(from:))
    }

    public func searchHistory(query: String, limit: Int) async throws -> [HistoryItem] {
        try await openHistory().entries(matching: query, limit: limit).map(Self.item(from:))
    }

    private static func item(from entry: HistoryEntry) -> HistoryItem {
        HistoryItem(
            url: entry.url.absoluteString,
            title: entry.title,
            visitCount: entry.visitCount,
            lastVisit: entry.lastVisit
        )
    }

    // MARK: Bookmarks

    public func bookmarkList() async throws -> [BookmarkItem] {
        try await openBookmarks().all().map { bookmark in
            BookmarkItem(
                title: bookmark.title,
                url: bookmark.url.absoluteString,
                folder: bookmark.folder,
                created: bookmark.created
            )
        }
    }

    // MARK: Session

    public func lastSavedSession() async throws -> SavedSessionReport {
        let path = location.sessionSnapshot
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw BrowserSnapshotError.sessionSnapshotMissing(path: path.path)
        }
        let store = try await SessionStore(directory: location.directory)
        guard let snapshot = await store.load() else {
            throw BrowserSnapshotError.sessionSnapshotUnreadable(path: path.path)
        }
        let windows = snapshot.windows.map { window in
            SavedWindowItem(
                selectedIndex: window.selectedIndex,
                tabs: window.tabs.map { tab in
                    // `tab.interactionState` is intentionally not read.
                    SavedTabItem(url: tab.url?.absoluteString, title: tab.title, isPinned: tab.isPinned)
                }
            )
        }
        let age = Int(now().timeIntervalSince(snapshot.savedAt).rounded())
        return SavedSessionReport(savedAt: snapshot.savedAt, ageSeconds: max(0, age), windows: windows)
    }

    // MARK: Lazy opening

    /// Opens `browser.db` only if it already exists. `SQLiteDatabase(url:)`
    /// passes `SQLITE_OPEN_CREATE`, so skipping this check would silently mint
    /// an empty database next to a profile that simply is not there.
    private func openDatabase() throws -> SQLiteDatabase {
        if let database { return database }
        let path = location.browserDatabase
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw BrowserSnapshotError.databaseMissing(path: path.path)
        }
        let opened = try SQLiteDatabase(url: path)
        database = opened
        return opened
    }

    private func openHistory() async throws -> HistoryStore {
        if let history { return history }
        let store = try await HistoryStore(database: try openDatabase())
        history = store
        return store
    }

    private func openBookmarks() async throws -> BookmarkStore {
        if let bookmarks { return bookmarks }
        let store = try await BookmarkStore(database: try openDatabase())
        bookmarks = store
        return store
    }
}
