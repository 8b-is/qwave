import Foundation
import Persistence

/// One row in the omnibox suggestions dropdown.
public struct OmniboxSuggestion: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case history
        case bookmark
        /// Switch to an already-open tab rather than loading a new page.
        case openTab(id: UUID)
        /// A quick action (command palette entry) that navigates to `url`.
        case action
        case search(provider: String)
    }

    public let url: URL
    public let title: String
    public let kind: Kind

    public init(url: URL, title: String, kind: Kind = .history) {
        self.url = url
        self.title = title
        self.kind = kind
    }
}

/// A snapshot of an open tab, passed to the on-device suggester so a typed
/// query can offer "switch to this tab" without depending on the app's
/// `@MainActor` `Tab` type.
public struct OpenTabInfo: Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let url: URL

    public init(id: UUID, title: String, url: URL) {
        self.id = id
        self.title = title
        self.url = url
    }

    var displayTitle: String { title.isEmpty ? (url.host ?? url.absoluteString) : title }
}

/// A quick action offered by the omnibox command palette. Matched on its
/// title and keyword aliases; committing navigates to `url` (typically an
/// internal `qwave://` page), so it rides the existing commit path.
public struct OmniboxAction: Equatable, Sendable {
    public let title: String
    public let keywords: [String]
    public let url: URL

    public init(title: String, keywords: [String], url: URL) {
        self.title = title
        self.keywords = keywords
        self.url = url
    }

    /// The default on-device actions. All targets are local internal pages —
    /// no network involved.
    public static let defaults: [OmniboxAction] = [
        OmniboxAction(
            title: "Open Start Page",
            keywords: ["start", "home", "new tab", "dashboard"],
            url: InternalPages.startURL
        ),
        OmniboxAction(
            title: "Open Timeline",
            keywords: ["timeline", "memories", "recall", "activity"],
            url: InternalPages.timelineURL
        ),
    ]

    /// `query` is expected pre-trimmed and lowercased.
    func matchScore(_ query: String) -> Double? {
        let loweredTitle = title.lowercased()
        if loweredTitle.hasPrefix(query) { return 70 }
        for keyword in keywords where keyword.lowercased().hasPrefix(query) { return 65 }
        if loweredTitle.contains(query) { return 45 }
        for keyword in keywords where keyword.lowercased().contains(query) { return 42 }
        return nil
    }
}

/// Ranks history entries and blends remote search suggestions against the typed omnibox query.
public enum OmniboxSuggester {
    public static func suggestions(
        for query: String,
        history: [HistoryEntry],
        now: Date = Date(),
        limit: Int = 6
    ) -> [OmniboxSuggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }

        // Bounded insertion sort with URL deduplication — only keep the
        // top `limit` entries instead of sorting the full set.
        var best: [(score: Double, entry: HistoryEntry)] = []
        best.reserveCapacity(limit + 1)
        var seenURLs: Set<String> = []
        seenURLs.reserveCapacity(limit)

        for entry in history {
            guard let base = matchScore(trimmed, entry: entry) else { continue }
            let frequency = 5.0 * log2(Double(entry.visitCount) + 1)
            let age = now.timeIntervalSince(entry.lastVisit)
            let recency: Double = age < 7 * 86_400 ? 10 : (age < 30 * 86_400 ? 5 : 0)
            let score = base + frequency + recency

            let key = entry.url.absoluteString
            guard seenURLs.insert(key).inserted else { continue }

            // Insert in sorted position, capped at `limit`.
            let insertIndex = best.firstIndex { $0.score < score } ?? best.endIndex
            best.insert((score, entry), at: insertIndex)
            if best.count > limit {
                best.removeLast()
            }
        }

        return best.map { OmniboxSuggestion(url: $0.entry.url, title: $0.entry.title, kind: .history) }
    }

    /// Fuses the on-device sources — open tabs, history, bookmarks, and quick
    /// actions — into a single ranked list. No network is consulted here; this
    /// is the privacy-preserving default path.
    ///
    /// Open tabs, history, and bookmarks that resolve to the same URL collapse
    /// to one row (the highest-scored wins — open tabs are weighted to win, so
    /// a match you already have open surfaces as "switch to tab").
    public static func onDeviceSuggestions(
        for query: String,
        history: [HistoryEntry],
        bookmarks: [Bookmark] = [],
        openTabs: [OpenTabInfo] = [],
        actions: [OmniboxAction] = [],
        now: Date = Date(),
        limit: Int = 6
    ) -> [OmniboxSuggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }

        var scored: [(score: Double, suggestion: OmniboxSuggestion)] = []
        var seenKeys: Set<String> = []

        func consider(_ score: Double, _ suggestion: OmniboxSuggestion, key: String) {
            guard seenKeys.insert(key).inserted else { return }
            scored.append((score, suggestion))
        }

        // Open tabs rank highest: switching to a page you already have open is
        // higher value than reloading it.
        for tab in openTabs {
            let urlString = tab.url.absoluteString
            guard let base = matchScore(trimmed, host: tab.url.host, urlString: urlString, title: tab.title) else {
                continue
            }
            consider(
                base + 25,
                OmniboxSuggestion(url: tab.url, title: tab.displayTitle, kind: .openTab(id: tab.id)),
                key: "url:\(urlString)"
            )
        }

        // History, weighted by frequency and recency (same formula as the
        // history-only path).
        for entry in history {
            let urlString = entry.url.absoluteString
            guard let base = matchScore(trimmed, host: entry.url.host, urlString: urlString, title: entry.title) else {
                continue
            }
            let frequency = 5.0 * log2(Double(entry.visitCount) + 1)
            let age = now.timeIntervalSince(entry.lastVisit)
            let recency: Double = age < 7 * 86_400 ? 10 : (age < 30 * 86_400 ? 5 : 0)
            consider(
                base + frequency + recency,
                OmniboxSuggestion(url: entry.url, title: entry.title, kind: .history),
                key: "url:\(urlString)"
            )
        }

        // Bookmarks: a small bonus over a bare history match — the user chose to save them.
        for bookmark in bookmarks {
            let urlString = bookmark.url.absoluteString
            guard let base = matchScore(trimmed, host: bookmark.url.host, urlString: urlString, title: bookmark.title)
            else { continue }
            consider(
                base + 8,
                OmniboxSuggestion(url: bookmark.url, title: bookmark.title, kind: .bookmark),
                key: "url:\(urlString)"
            )
        }

        // Quick actions, matched on title/keyword aliases.
        for action in actions {
            guard let base = action.matchScore(trimmed) else { continue }
            consider(
                base,
                OmniboxSuggestion(url: action.url, title: action.title, kind: .action),
                key: "action:\(action.url.absoluteString)"
            )
        }

        // Stable order: score descending, insertion order breaking ties.
        return scored.enumerated()
            .sorted { lhs, rhs in
                lhs.element.score != rhs.element.score
                    ? lhs.element.score > rhs.element.score
                    : lhs.offset < rhs.offset
            }
            .prefix(limit)
            .map(\.element.suggestion)
    }

    /// Blends on-device suggestions with remote search engine suggestions.
    ///
    /// The remote list must only ever be non-empty when the user has opted in
    /// to network suggestions — the caller is responsible for that gate.
    public static func hybridSuggestions(
        for query: String,
        history: [HistoryEntry],
        bookmarks: [Bookmark] = [],
        openTabs: [OpenTabInfo] = [],
        actions: [OmniboxAction] = [],
        remoteSuggestions: [RemoteSearchSuggestion] = [],
        searchURLBuilder: (String) -> URL? = { query in
            guard let enc = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
            return URL(string: "https://duckduckgo.com/?q=\(enc)")
        },
        now: Date = Date(),
        limit: Int = 6
    ) -> [OmniboxSuggestion] {
        let local = onDeviceSuggestions(
            for: query,
            history: history,
            bookmarks: bookmarks,
            openTabs: openTabs,
            actions: actions,
            now: now,
            limit: limit
        )
        var combined = local
        var seenTexts = Set(local.map { $0.title.lowercased() })

        for remote in remoteSuggestions {
            guard combined.count < limit else { break }
            let lower = remote.text.lowercased()
            guard !seenTexts.contains(lower), let searchURL = searchURLBuilder(remote.text) else { continue }
            seenTexts.insert(lower)
            combined.append(
                OmniboxSuggestion(
                    url: searchURL,
                    title: remote.text,
                    kind: .search(provider: remote.provider)
                )
            )
        }

        return combined
    }

    private static func matchScore(_ query: String, entry: HistoryEntry) -> Double? {
        matchScore(query, host: entry.url.host, urlString: entry.url.absoluteString, title: entry.title)
    }

    /// Scores a candidate (history entry, bookmark, or open tab) against the
    /// query. Higher is a better match; nil means no match at all.
    static func matchScore(_ query: String, host rawHost: String?, urlString rawURL: String, title rawTitle: String)
        -> Double?
    {
        let host = (rawHost ?? "").lowercased()
        let hostSansWWW = host.hasPrefix("www.") ? host[host.index(host.startIndex, offsetBy: 4)...] : Substring(host)
        let urlString = rawURL.lowercased()
        // Strip scheme via prefix drop instead of replacingOccurrences.
        let urlSansScheme: Substring
        if urlString.hasPrefix("https://") {
            urlSansScheme = urlString[urlString.index(urlString.startIndex, offsetBy: 8)...]
        } else if urlString.hasPrefix("http://") {
            urlSansScheme = urlString[urlString.index(urlString.startIndex, offsetBy: 7)...]
        } else {
            urlSansScheme = Substring(urlString)
        }
        let title = rawTitle.lowercased()

        if hostSansWWW.hasPrefix(query) || host.hasPrefix(query) { return 100 }
        if urlSansScheme.hasPrefix(query) { return 90 }
        if hostSansWWW.contains(query) { return 60 }
        if title.hasPrefix(query) { return 50 }
        if title.contains(query) { return 40 }
        if urlSansScheme.contains(query) { return 30 }
        return nil
    }
}
