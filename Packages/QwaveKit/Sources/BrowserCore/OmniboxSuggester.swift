import Foundation
import Persistence

/// One row in the omnibox suggestions dropdown.
public struct OmniboxSuggestion: Equatable, Sendable {
    public let url: URL
    public let title: String

    public init(url: URL, title: String) {
        self.url = url
        self.title = title
    }
}

/// Ranks history entries against the typed omnibox query. Pure logic — the
/// dropdown UI feeds it `HistoryStore.entries(matching:)` results and renders
/// what comes back.
///
/// Scoring favors what address bars are actually used for: host prefixes
/// beat URL prefixes beat substring hits, frequently and recently visited
/// pages float up, and one URL never appears twice.
///
/// Optimised for the keystroke path: bounded partial sort instead of a full
/// sort, scheme stripping via prefix checks instead of replacingOccurrences,
/// and a single lowercased pass per entry.
public enum OmniboxSuggester {
    @inlinable
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

        return best.map { OmniboxSuggestion(url: $0.entry.url, title: $0.entry.title) }
    }

    @usableFromInline
    static func matchScore(_ query: String, entry: HistoryEntry) -> Double? {
        let host = (entry.url.host ?? "").lowercased()
        let hostSansWWW = host.hasPrefix("www.") ? host[host.index(host.startIndex, offsetBy: 4)...] : Substring(host)
        let urlString = entry.url.absoluteString.lowercased()
        // Strip scheme via prefix drop instead of replacingOccurrences.
        let urlSansScheme: Substring
        if urlString.hasPrefix("https://") {
            urlSansScheme = urlString[urlString.index(urlString.startIndex, offsetBy: 8)...]
        } else if urlString.hasPrefix("http://") {
            urlSansScheme = urlString[urlString.index(urlString.startIndex, offsetBy: 7)...]
        } else {
            urlSansScheme = Substring(urlString)
        }
        let title = entry.title.lowercased()

        if hostSansWWW.hasPrefix(query) || host.hasPrefix(query) { return 100 }
        if urlSansScheme.hasPrefix(query) { return 90 }
        if hostSansWWW.contains(query) { return 60 }
        if title.hasPrefix(query) { return 50 }
        if title.contains(query) { return 40 }
        if urlSansScheme.contains(query) { return 30 }
        return nil
    }
}
