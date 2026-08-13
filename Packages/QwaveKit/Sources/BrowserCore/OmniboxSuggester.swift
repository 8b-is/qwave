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
public enum OmniboxSuggester {
    public static func suggestions(
        for query: String,
        history: [HistoryEntry],
        now: Date = Date(),
        limit: Int = 6
    ) -> [OmniboxSuggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }

        var best: [String: (score: Double, entry: HistoryEntry)] = [:]
        for entry in history {
            guard let base = matchScore(trimmed, entry: entry) else { continue }
            let frequency = 5.0 * log2(Double(entry.visitCount) + 1)
            let age = now.timeIntervalSince(entry.lastVisit)
            let recency: Double = age < 7 * 86_400 ? 10 : (age < 30 * 86_400 ? 5 : 0)
            let score = base + frequency + recency

            let key = entry.url.absoluteString
            if let existing = best[key], existing.score >= score { continue }
            best[key] = (score, entry)
        }

        return best.values
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.entry.lastVisit > rhs.entry.lastVisit
            }
            .prefix(limit)
            .map { OmniboxSuggestion(url: $0.entry.url, title: $0.entry.title) }
    }

    private static func matchScore(_ query: String, entry: HistoryEntry) -> Double? {
        let host = (entry.url.host ?? "").lowercased()
        let hostSansWWW = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let urlString = entry.url.absoluteString.lowercased()
        let urlSansScheme = urlString
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
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
