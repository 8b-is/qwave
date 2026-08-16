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
            // One `absoluteString` per entry: it feeds both the match and the
            // dedup key, and building it twice cost an allocation per entry
            // on every keystroke.
            let urlString = entry.url.absoluteString
            guard let base = matchScore(trimmed, host: entry.url.host, urlString: urlString, title: entry.title)
            else { continue }
            let frequency = 5.0 * log2(Double(entry.visitCount) + 1)
            let age = now.timeIntervalSince(entry.lastVisit)
            let recency: Double = age < 7 * 86_400 ? 10 : (age < 30 * 86_400 ? 5 : 0)
            let score = base + frequency + recency

            guard seenURLs.insert(urlString).inserted else { continue }

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
        var seenKeys: Set<DedupKey> = []

        func consider(_ score: Double, _ suggestion: OmniboxSuggestion, key: DedupKey) {
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
                key: .url(urlString)
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
                key: .url(urlString)
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
                key: .url(urlString)
            )
        }

        // Quick actions, matched on title/keyword aliases.
        for action in actions {
            guard let base = action.matchScore(trimmed) else { continue }
            consider(
                base,
                OmniboxSuggestion(url: action.url, title: action.title, kind: .action),
                key: .action(action.url.absoluteString)
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

    /// Namespaces a dedup key without building a prefixed `String` per
    /// candidate. The old `"url:\(urlString)"` / `"action:\(...)"` keys
    /// allocated one throwaway String per row on every keystroke purely to
    /// keep the two namespaces apart; the case discriminator does that for
    /// free.
    private enum DedupKey: Hashable {
        case url(String)
        case action(String)
    }

    /// Scores a candidate (history entry, bookmark, or open tab) against the
    /// query. Higher is a better match; nil means no match at all.
    ///
    /// `query` is expected pre-trimmed and lowercased; only the candidate side
    /// is case-folded here.
    static func matchScore(_ query: String, host rawHost: String?, urlString rawURL: String, title rawTitle: String)
        -> Double?
    {
        let rawHost = rawHost ?? ""
        // The ASCII path is the overwhelmingly common one and allocates
        // nothing; the Unicode path is a verbatim fallback. See
        // `isASCIIFoldable` for why the split is safe.
        if isASCIIFoldable(query), isASCIIFoldable(rawHost), isASCIIFoldable(rawURL), isASCIIFoldable(rawTitle) {
            return asciiMatchScore(query, host: rawHost, urlString: rawURL, title: rawTitle)
        }
        return unicodeMatchScore(query, host: rawHost, urlString: rawURL, title: rawTitle)
    }

    /// Allocation-free scoring over the raw UTF-8 bytes.
    ///
    /// Structurally identical to `unicodeMatchScore` — same tiers, same order,
    /// same short-circuits — but it case-folds a byte at a time while
    /// comparing instead of materialising three lowercased `String`s per
    /// candidate. Those three strings were the omnibox's hottest allocation
    /// site: they were rebuilt for every history row on every keystroke, over
    /// data that had not changed.
    private static func asciiMatchScore(
        _ query: String, host rawHost: String, urlString rawURL: String, title rawTitle: String
    ) -> Double? {
        let needle = query.utf8
        let host = rawHost.utf8
        // `dropFirst(0)` rather than the bare view so both branches share one
        // type (and so no copy is made either way).
        let hostSansWWW = asciiHasPrefix(host, "www.".utf8) ? host.dropFirst(4) : host.dropFirst(0)

        let url = rawURL.utf8
        let urlSansScheme: Substring.UTF8View
        if asciiHasPrefix(url, "https://".utf8) {
            urlSansScheme = url.dropFirst(8)
        } else if asciiHasPrefix(url, "http://".utf8) {
            urlSansScheme = url.dropFirst(7)
        } else {
            urlSansScheme = url.dropFirst(0)
        }
        let title = rawTitle.utf8

        if asciiHasPrefix(hostSansWWW, needle) || asciiHasPrefix(host, needle) { return 100 }
        if asciiHasPrefix(urlSansScheme, needle) { return 90 }
        if asciiContains(hostSansWWW, needle) { return 60 }
        if asciiHasPrefix(title, needle) { return 50 }
        if asciiContains(title, needle) { return 40 }
        if asciiContains(urlSansScheme, needle) { return 30 }
        return nil
    }

    /// The original, Unicode-correct scoring. Retained verbatim as the
    /// fallback for anything `asciiMatchScore` must not touch, so those
    /// candidates rank exactly as they always did.
    private static func unicodeMatchScore(
        _ query: String, host rawHost: String, urlString rawURL: String, title rawTitle: String
    ) -> Double? {
        let host = rawHost.lowercased()
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

    // MARK: - Byte-wise case-insensitive matching

    /// True when `string` can be matched byte-wise without changing the answer
    /// `lowercased()` would have given.
    ///
    /// Two things have to hold, and both fail outside this set:
    ///
    /// 1. **Lowercasing must be byte-local.** For `A...Z` it is exactly
    ///    `| 0x20`. Outside ASCII it is not: `İ` (U+0130) lowercases to *two*
    ///    scalars, `K` (U+212A KELVIN SIGN) lowercases to plain ASCII `k`, and
    ///    `ß` lowercases to itself while `SS` lowercases to `ss`. A byte-wise
    ///    fold would miss or invent matches in all three cases.
    /// 2. **String comparison must be byte equality.** Swift compares under
    ///    canonical equivalence, so `e` + U+0301 equals `é`; and CR LF is a
    ///    single grapheme cluster, the one place ASCII has a multi-scalar
    ///    character. CR is therefore excluded along with everything >= 0x80.
    ///
    /// Anything rejected here goes to `unicodeMatchScore` unchanged, so this
    /// is a fast path, never a behaviour change.
    private static func isASCIIFoldable(_ string: String) -> Bool {
        !string.utf8.contains { $0 >= 0x80 || $0 == 0x0D }
    }

    @inline(__always)
    private static func asciiLowercased(_ byte: UInt8) -> UInt8 {
        (byte &- 0x41) < 26 ? byte | 0x20 : byte
    }

    /// `haystack` is folded to lowercase as it is read; `needle` is compared
    /// as-is, because callers pass an already-lowercased query — exactly what
    /// the `String` version did.
    private static func asciiHasPrefix<Haystack: Collection, Needle: Collection>(
        _ haystack: Haystack, _ needle: Needle
    ) -> Bool where Haystack.Element == UInt8, Needle.Element == UInt8 {
        var bytes = haystack.makeIterator()
        for wanted in needle {
            guard let byte = bytes.next(), asciiLowercased(byte) == wanted else { return false }
        }
        return true
    }

    /// Naive sliding search. The needle is the handful of characters the user
    /// has typed and the haystack a single URL or title, so the quadratic
    /// worst case is not reachable at these sizes.
    private static func asciiContains<Haystack: Collection, Needle: Collection>(
        _ haystack: Haystack, _ needle: Needle
    ) -> Bool where Haystack.Element == UInt8, Needle.Element == UInt8 {
        if needle.isEmpty { return true }
        var start = haystack.startIndex
        while start != haystack.endIndex {
            if asciiHasPrefix(haystack[start...], needle) { return true }
            haystack.formIndex(after: &start)
        }
        return false
    }
}
