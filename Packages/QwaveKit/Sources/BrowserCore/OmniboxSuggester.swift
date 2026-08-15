import Foundation
import Persistence

/// One row in the omnibox suggestions dropdown.
public struct OmniboxSuggestion: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case history
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

    /// Blends local history suggestions with remote search engine suggestions.
    public static func hybridSuggestions(
        for query: String,
        history: [HistoryEntry],
        remoteSuggestions: [RemoteSearchSuggestion] = [],
        searchURLBuilder: (String) -> URL? = { query in
            guard let enc = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
            return URL(string: "https://duckduckgo.com/?q=\(enc)")
        },
        now: Date = Date(),
        limit: Int = 6
    ) -> [OmniboxSuggestion] {
        let local = suggestions(for: query, history: history, now: now, limit: limit)
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
