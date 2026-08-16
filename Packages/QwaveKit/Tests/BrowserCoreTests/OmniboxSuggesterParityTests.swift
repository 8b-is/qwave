import XCTest
import Persistence
@testable import BrowserCore

/// Differential tests for the omnibox ranking optimisation.
///
/// The optimisation is meant to be *purely* an allocation reduction: the
/// ordered result of every entry point must stay byte-identical. These tests
/// pin that by re-implementing the pre-optimisation ranking verbatim
/// (`LegacyOmniboxSuggester`) and asserting the shipping implementation agrees
/// with it over a deliberately messy corpus — uppercase hosts, `www.`
/// prefixes, IDN and punycode, empty titles, query strings, duplicate URLs,
/// ports, and non-ASCII titles.
///
/// If these ever diverge, the shipping ranking has drifted. Fix the
/// implementation, not the expectation.
final class OmniboxSuggesterParityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - The pre-optimisation implementation, verbatim

    private enum LegacyOmniboxSuggester {
        static func suggestions(
            for query: String,
            history: [HistoryEntry],
            now: Date,
            limit: Int = 6
        ) -> [OmniboxSuggestion] {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty else { return [] }

            var best: [(score: Double, entry: HistoryEntry)] = []
            best.reserveCapacity(limit + 1)
            var seenURLs: Set<String> = []
            seenURLs.reserveCapacity(limit)

            for entry in history {
                guard
                    let base = matchScore(
                        trimmed, host: entry.url.host, urlString: entry.url.absoluteString, title: entry.title)
                else { continue }
                let frequency = 5.0 * log2(Double(entry.visitCount) + 1)
                let age = now.timeIntervalSince(entry.lastVisit)
                let recency: Double = age < 7 * 86_400 ? 10 : (age < 30 * 86_400 ? 5 : 0)
                let score = base + frequency + recency

                let key = entry.url.absoluteString
                guard seenURLs.insert(key).inserted else { continue }

                let insertIndex = best.firstIndex { $0.score < score } ?? best.endIndex
                best.insert((score, entry), at: insertIndex)
                if best.count > limit {
                    best.removeLast()
                }
            }

            return best.map { OmniboxSuggestion(url: $0.entry.url, title: $0.entry.title, kind: .history) }
        }

        static func onDeviceSuggestions(
            for query: String,
            history: [HistoryEntry],
            bookmarks: [Bookmark] = [],
            openTabs: [OpenTabInfo] = [],
            actions: [OmniboxAction] = [],
            now: Date,
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

            for tab in openTabs {
                let urlString = tab.url.absoluteString
                guard let base = matchScore(trimmed, host: tab.url.host, urlString: urlString, title: tab.title)
                else { continue }
                consider(
                    base + 25,
                    OmniboxSuggestion(url: tab.url, title: tab.displayTitle, kind: .openTab(id: tab.id)),
                    key: "url:\(urlString)"
                )
            }

            for entry in history {
                let urlString = entry.url.absoluteString
                guard let base = matchScore(trimmed, host: entry.url.host, urlString: urlString, title: entry.title)
                else { continue }
                let frequency = 5.0 * log2(Double(entry.visitCount) + 1)
                let age = now.timeIntervalSince(entry.lastVisit)
                let recency: Double = age < 7 * 86_400 ? 10 : (age < 30 * 86_400 ? 5 : 0)
                consider(
                    base + frequency + recency,
                    OmniboxSuggestion(url: entry.url, title: entry.title, kind: .history),
                    key: "url:\(urlString)"
                )
            }

            for bookmark in bookmarks {
                let urlString = bookmark.url.absoluteString
                guard
                    let base = matchScore(
                        trimmed, host: bookmark.url.host, urlString: urlString, title: bookmark.title)
                else { continue }
                consider(
                    base + 8,
                    OmniboxSuggestion(url: bookmark.url, title: bookmark.title, kind: .bookmark),
                    key: "url:\(urlString)"
                )
            }

            for action in actions {
                guard let base = action.matchScore(trimmed) else { continue }
                consider(
                    base,
                    OmniboxSuggestion(url: action.url, title: action.title, kind: .action),
                    key: "action:\(action.url.absoluteString)"
                )
            }

            return scored.enumerated()
                .sorted { lhs, rhs in
                    lhs.element.score != rhs.element.score
                        ? lhs.element.score > rhs.element.score
                        : lhs.offset < rhs.offset
                }
                .prefix(limit)
                .map(\.element.suggestion)
        }

        static func matchScore(_ query: String, host rawHost: String?, urlString rawURL: String, title rawTitle: String)
            -> Double?
        {
            let host = (rawHost ?? "").lowercased()
            let hostSansWWW =
                host.hasPrefix("www.") ? host[host.index(host.startIndex, offsetBy: 4)...] : Substring(host)
            let urlString = rawURL.lowercased()
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

    // MARK: - Messy corpus

    /// URL/title shapes chosen to exercise every branch of `matchScore` and
    /// every way the lowercasing could go wrong.
    private static let messyShapes: [(url: String, title: String)] = [
        ("https://GitHub.com/Apple/Swift", "Apple Swift on GitHub"),
        ("https://www.WebKit.org/", "WebKit"),
        ("https://www.webkit.org/blog/", ""),
        ("http://example.com", "Example"),
        ("http://EXAMPLE.COM/PATH?Q=Value#Frag", "EXAMPLE UPPER"),
        ("https://example.com/", "Example"),
        ("https://example.com/", "Example duplicate URL"),
        ("https://xn--bcher-kva.example/", "Bücher (punycode host)"),
        ("https://bücher.example/seite", "Bücher direkt"),
        ("https://ünïcode.example/pfad?q=ä", "Ünïcode Ẅïth Ümläüts"),
        ("https://пример.example/", "Пример по-русски"),
        ("https://xn--e1afmkfd.example/path", "Пример punycode"),
        ("https://sub.example.co.uk:8443/a?b=c#d", "Deep subdomain with port"),
        ("https://www.WWW.example/", "www inside www"),
        ("https://wwwexample.com/", "no dot after www"),
        ("https://site.example/?query=SITE&other=site", "Query string carries the term"),
        ("https://site.example/path/site/site", "Repeated path segment"),
        ("ftp://files.example/pub", "FTP no-scheme-strip case"),
        ("qwave://start", "Qwave Start Page"),
        ("https://a.example/", ""),
        ("https://İstanbul.example/", "İstanbul dotted capital I"),
        ("https://STRASSE.example/", "STRASSE vs Straße"),
        ("https://straße.example/", "Straße sharp s"),
        ("https://user:pw@auth.example/secret", "Credentials in URL"),
        ("https://192.168.1.10:3000/dash", "IP literal host"),
        ("https://[2001:db8::1]/v6", "IPv6 literal host"),
        ("https://trailing.example/path%20with%20escapes", "Percent escapes"),
        ("https://emoji.example/path", "Title with emoji 🌊 wave"),
        ("https://very-long-host-name-for-prefix-tests.example/deep/path/segment", "Long host"),
        ("https://Site9.Example/Page/9", "Mixed case site9"),
        // CR LF is the one multi-scalar grapheme cluster in ASCII, and
        // U+212A KELVIN SIGN lowercases to a plain ASCII `k` — the two
        // shapes a byte-wise fold would get wrong if it were let near them.
        ("https://crlf.example/one", "line\r\nbreak in title"),
        ("https://kelvin.example/\u{212A}", "\u{212A}elvin sign lowercases to ASCII k"),
        ("https://\u{0130}dotted.example/", "Dotted capital \u{0130} in host"),
    ]

    private func corpus() -> (history: [HistoryEntry], bookmarks: [Bookmark], openTabs: [OpenTabInfo]) {
        var history: [HistoryEntry] = []
        var bookmarks: [Bookmark] = []
        var openTabs: [OpenTabInfo] = []

        // ~360 history entries: the messy shapes repeated with varying visit
        // counts / recency (so scoring ties and tie-breaks both get exercised),
        // plus a synthetic bulk set.
        // Some of the deliberately messy strings do not survive `URL(string:)`
        // on a strict RFC 3986 Foundation. That is fine — they simply cannot
        // reach the suggester in production either — but the ones that do
        // survive still have to rank identically, and the non-ASCII *titles*
        // exercise the Unicode fallback regardless.
        let shapes = Self.messyShapes.filter { URL(string: $0.url) != nil }
        XCTAssertGreaterThan(shapes.count, 20, "corpus collapsed — almost nothing parsed as a URL")

        var identifier: Int64 = 0
        for repetition in 0..<6 {
            for (index, shape) in shapes.enumerated() {
                guard let url = URL(string: shape.url) else { continue }
                identifier += 1
                history.append(
                    HistoryEntry(
                        id: identifier,
                        url: url,
                        title: repetition == 0 ? shape.title : "\(shape.title) #\(repetition)",
                        visitCount: (index * 7 + repetition * 3) % 41 + 1,
                        lastVisit: now.addingTimeInterval(-Double(index * 6 + repetition) * 86_400 / 4),
                        containerID: nil
                    )
                )
            }
        }
        for index in 0..<180 {
            identifier += 1
            history.append(
                HistoryEntry(
                    id: identifier,
                    url: URL(string: "https://site\(index % 97).example/page/\(index)")!,
                    title: "Page \(index) about topic \(index % 13)",
                    visitCount: index % 40 + 1,
                    lastVisit: now.addingTimeInterval(-Double(index) * 3600),
                    containerID: nil
                )
            )
        }

        for (index, shape) in shapes.enumerated() where index % 3 == 0 {
            guard let url = URL(string: shape.url) else { continue }
            bookmarks.append(
                Bookmark(id: Int64(index), title: "BM \(shape.title)", url: url, folder: nil, created: now)
            )
        }
        for (index, shape) in shapes.enumerated() where index % 5 == 0 {
            guard let url = URL(string: shape.url),
                let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))
            else { continue }
            openTabs.append(
                OpenTabInfo(id: id, title: index % 2 == 0 ? "Tab \(shape.title)" : "", url: url)
            )
        }
        return (history, bookmarks, openTabs)
    }

    /// A spread of queries: prefixes, infixes, whole hosts, non-ASCII, mixed
    /// case, whitespace-padded, punctuation, and misses.
    private static let queries: [String] = [
        "s", "si", "sit", "site", "site9", "site1",
        "e", "ex", "exa", "example", "example.com", "example.com/path",
        "g", "git", "github", "github.com/apple",
        "w", "www", "webkit", "webkit.org", "www.webkit",
        "b", "bü", "bücher", "buch", "xn--", "xn--bcher",
        "п", "при", "пример", "İst", "ist", "istanbul",
        "stra", "straße", "strasse", "STRASSE",
        "8443", "sub.example", "co.uk", "2001:db8", "192.168",
        "q=", "query=site", "?q", "#d", "%20", "path%20with",
        "🌊", "wave", "emoji",
        "GitHub", "  webkit  ", "\tSITE\n", "  ", "",
        "qwave", "qwave://", "ftp", "files.example",
        "topic 3", "page 12", "about topic",
        "start", "timeline", "memories", "dashboard", "recall",
        "zzzz-no-match", "..", "://", "user:pw", "auth.example",
        "trailing", "long-host", "very-long-host-name-for-prefix-tests",
        "no dot", "wwwexample", "a.example", "deep/path",
        "e\r\nb", "line\r\n", "\r\nbreak", "kelvin", "k", "\u{212A}", "elvin",
        "dotted", "i\u{0307}dotted", "\u{0130}dotted",
    ]

    // MARK: - Parity

    func testHistoryOnlyPathMatchesLegacyForEveryQuery() {
        let corpus = corpus()
        for query in Self.queries {
            for limit in [1, 6, 20] {
                let expected = LegacyOmniboxSuggester.suggestions(
                    for: query, history: corpus.history, now: now, limit: limit)
                let actual = OmniboxSuggester.suggestions(
                    for: query, history: corpus.history, now: now, limit: limit)
                XCTAssertEqual(
                    actual, expected,
                    "history-only ranking drifted for query \(String(reflecting: query)) limit \(limit)")
            }
        }
    }

    func testOnDevicePathMatchesLegacyForEveryQuery() {
        let corpus = corpus()
        for query in Self.queries {
            for limit in [1, 6, 20] {
                let expected = LegacyOmniboxSuggester.onDeviceSuggestions(
                    for: query,
                    history: corpus.history,
                    bookmarks: corpus.bookmarks,
                    openTabs: corpus.openTabs,
                    actions: OmniboxAction.defaults,
                    now: now,
                    limit: limit
                )
                let actual = OmniboxSuggester.onDeviceSuggestions(
                    for: query,
                    history: corpus.history,
                    bookmarks: corpus.bookmarks,
                    openTabs: corpus.openTabs,
                    actions: OmniboxAction.defaults,
                    now: now,
                    limit: limit
                )
                XCTAssertEqual(
                    actual, expected,
                    "on-device ranking drifted for query \(String(reflecting: query)) limit \(limit)")
            }
        }
    }

    /// `matchScore` is the unit under the ranking; compare it directly so a
    /// divergence points at the scorer rather than at the surrounding sort.
    func testMatchScoreMatchesLegacyOverTheFullCrossProduct() {
        let corpus = corpus()
        let candidates =
            corpus.history.map { (host: $0.url.host, url: $0.url.absoluteString, title: $0.title) }
            + corpus.bookmarks.map { (host: $0.url.host, url: $0.url.absoluteString, title: $0.title) }

        // The byte-wise fast path only applies to pure-ASCII, CR-free strings;
        // everything else falls back. Both halves have to actually be reached
        // or this test is only checking one of them.
        func isByteFoldable(_ string: String) -> Bool {
            !string.utf8.contains { $0 >= 0x80 || $0 == 0x0D }
        }
        let foldable = candidates.filter {
            isByteFoldable($0.host ?? "") && isByteFoldable($0.url) && isByteFoldable($0.title)
        }
        XCTAssertFalse(foldable.isEmpty, "no candidate reaches the byte-wise fast path")
        XCTAssertLessThan(
            foldable.count, candidates.count, "no candidate reaches the Unicode fallback — corpus is too clean")

        for query in Self.queries {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty else { continue }
            for candidate in candidates {
                let expected = LegacyOmniboxSuggester.matchScore(
                    trimmed, host: candidate.host, urlString: candidate.url, title: candidate.title)
                let actual = OmniboxSuggester.matchScore(
                    trimmed, host: candidate.host, urlString: candidate.url, title: candidate.title)
                XCTAssertEqual(
                    actual, expected,
                    "matchScore drifted: query \(String(reflecting: trimmed)) "
                        + "host \(String(reflecting: candidate.host)) url \(candidate.url) "
                        + "title \(String(reflecting: candidate.title))")
            }
        }
    }

    // MARK: - Degenerate inputs

    func testEmptyAndSingleEntryCasesMatchLegacy() {
        let single = [
            HistoryEntry(
                id: 1, url: URL(string: "https://example.com/")!, title: "Example", visitCount: 1,
                lastVisit: now, containerID: nil)
        ]
        for query in ["", "   ", "\n\t ", "e", "example", "zzz"] {
            XCTAssertEqual(
                OmniboxSuggester.suggestions(for: query, history: [], now: now),
                LegacyOmniboxSuggester.suggestions(for: query, history: [], now: now),
                "empty history diverged for \(String(reflecting: query))")
            XCTAssertEqual(
                OmniboxSuggester.suggestions(for: query, history: single, now: now),
                LegacyOmniboxSuggester.suggestions(for: query, history: single, now: now),
                "single entry diverged for \(String(reflecting: query))")
            XCTAssertEqual(
                OmniboxSuggester.onDeviceSuggestions(for: query, history: [], now: now),
                LegacyOmniboxSuggester.onDeviceSuggestions(for: query, history: [], now: now),
                "empty on-device diverged for \(String(reflecting: query))")
        }
    }
}
