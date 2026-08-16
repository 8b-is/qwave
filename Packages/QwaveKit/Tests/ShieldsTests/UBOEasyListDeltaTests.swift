import XCTest
import WebKit

@testable import Shields

/// The measurement issue #134 asks for: not "the JSON compiles now", but
/// **which rules start or stop matching** when the three rejected shapes are
/// changed, counted against the real upstream EasyList.
///
/// The list is not committed (CC BY-SA, ~3 MB), so this skips unless
/// `QWAVE_EASYLIST_PATH` points at one — the same convention
/// `UBORuleCompilerEquivalenceTests` already uses:
///
///     curl -o /tmp/easylist.txt https://easylist.to/easylist/easylist.txt
///     QWAVE_EASYLIST_PATH=/tmp/easylist.txt swift test …
///
/// The run recorded in the PR is quoted from `testEasyListDeltaReport`'s
/// output. Everything it prints, it also asserts, so the numbers cannot drift
/// away from the prose without a red test.
final class UBOEasyListDeltaTests: XCTestCase {

    private func easyList() throws -> String {
        guard let path = ProcessInfo.processInfo.environment["QWAVE_EASYLIST_PATH"] else {
            throw XCTSkip("set QWAVE_EASYLIST_PATH to diff against a real upstream list")
        }
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    private func matches(_ pattern: String, _ string: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        return expression.firstMatch(in: string, range: NSRange(location: 0, length: (string as NSString).length))
            != nil
    }

    /// URLs a rule for `token` could meet. Deliberately includes the two the
    /// dropped alternation branches used to cover: a bare authority, and the
    /// token ending the URL.
    private func probeURLs(_ token: String) -> [String] {
        [
            "https://\(token)/", "https://\(token)/a?b=c", "https://\(token):8443/x",
            "https://sub.\(token)/p", "https://\(token)",
            "https://other.test/p?u=\(token)&x=1", "https://other.test/p?u=\(token)",
            "https://\(token).evil.test/", "https://evil\(token)/",
        ]
    }

    struct Delta {
        var lines = 0
        var ignored = 0
        var blocking = 0
        var exceptions = 0
        var rulesBefore = 0
        var rulesAfter = 0
        /// Filters that were rejected by WebKit before and are accepted now.
        var unblockedByFix = 0
        /// Filters carrying `$third-party` / `$first-party`.
        var loadTypeFilters = 0
        /// Filters carrying both `$domain=a` and `$domain=~b`.
        var bothDomainConditions = 0
        /// …of which a negation actually overlapped a positive entry.
        var negationsGenuinelyLost = 0
        /// Filters whose url-filter is not ASCII, so WebKit cannot take them
        /// at all — pre-existing, unrelated to the three shapes.
        var nonASCIIFilters = 0
        /// Probe URLs where the old and new url-filter disagree.
        var urlsGained = 0
        var urlsLost = 0
        var urlsLostOnBareAuthority = 0
        /// Options-only filters (`$popup,domain=…`) now skipped rather than
        /// compiled into a match-everything rule — see `UBOFilterParser.parse`.
        var optionsOnlyFiltersSkipped = 0
    }

    /// An options-only line: everything before the `$` is empty once the
    /// anchors come off. Recomputed here rather than asked of the parser,
    /// because the parser's answer is now `.ignore` and the point is to count
    /// what changed.
    private func isOptionsOnly(_ line: String) -> Bool {
        var rule = line
        if rule.hasPrefix("!") || rule.hasPrefix("#") || rule.hasPrefix("[") { return false }
        if rule.contains("##") || rule.contains("#@#") || rule.contains("#?#") { return false }
        if rule.hasPrefix("@@") { rule.removeFirst(2) }
        guard let dollar = rule.lastIndex(of: "$") else { return false }
        var pattern = String(rule[..<dollar])
        if pattern.hasSuffix("^") { pattern.removeLast() }
        while pattern.hasPrefix("|") { pattern.removeFirst() }
        return pattern.isEmpty
    }

    /// The old shapes, verbatim, so the diff is a real differential.
    private func legacyURLFilter(_ parsed: UBOFilter) -> String? {
        func anchored(_ host: String) -> String {
            "^[a-z]+://([^/]+\\.)*\(UBORuleListCompiler.escapeHost(host))(:[0-9]+)?(/|$)"
        }
        switch parsed {
        case .ignore: return nil
        case .hostname(let host, _): return anchored(host)
        case .plain(let host, _):
            return "([^a-z0-9.-]|\\.)*\(UBORuleListCompiler.escapeHost(host))([^a-z0-9.-]|$)"
        case .anchoredPath(let host, let path, _):
            return anchored(host) + NSRegularExpression.escapedPattern(for: path)
        case .substring(let pattern, _): return NSRegularExpression.escapedPattern(for: pattern)
        case .exception(let pattern, _):
            return pattern.hasPrefix("||")
                ? anchored(String(pattern.dropFirst(2))) : NSRegularExpression.escapedPattern(for: pattern)
        }
    }

    private func newURLFilters(_ parsed: UBOFilter) -> [String] {
        UBORuleListCompiler.variants(of: parsed).compactMap { variant in
            guard let rule = UBORuleListCompiler.filter(parsed, variant: variant),
                let trigger = rule["trigger"] as? [String: Any]
            else { return nil }
            return trigger["url-filter"] as? String
        }
    }

    /// The token a rule is "about", for building probe URLs.
    private func token(_ parsed: UBOFilter) -> String? {
        switch parsed {
        case .hostname(let host, _), .plain(let host, _): return host
        case .anchoredPath(let host, _, _): return host
        case .ignore, .substring, .exception: return nil
        }
    }

    private func isBareAuthority(_ url: String) -> Bool {
        guard let schemeEnd = url.range(of: "://") else { return false }
        return !url[schemeEnd.upperBound...].contains("/")
    }

    func testEasyListDeltaReport() throws {
        let text = try easyList()
        var delta = Delta()

        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            delta.lines += 1
            let parsed = UBOFilterParser.parse(line)
            if case .ignore = parsed {
                delta.ignored += 1
                if isOptionsOnly(line) { delta.optionsOnlyFiltersSkipped += 1 }
                continue
            }
            if case .exception = parsed { delta.exceptions += 1 } else { delta.blocking += 1 }

            let options: UBOFilterOptions
            switch parsed {
            case .ignore: continue
            case .hostname(_, let o), .plain(_, let o), .substring(_, let o), .exception(_, let o): options = o
            case .anchoredPath(_, _, let o): options = o
            }
            if options.loadType != nil { delta.loadTypeFilters += 1 }
            if !options.domains.isEmpty && !options.notDomains.isEmpty {
                delta.bothDomainConditions += 1
                delta.negationsGenuinelyLost += UBORuleListCompiler.domainConditionLoses(options).count
            }

            let old = legacyURLFilter(parsed)
            let new = newURLFilters(parsed)
            delta.rulesBefore += old == nil ? 0 : 1
            delta.rulesAfter += new.count
            if new.contains(where: { !$0.allSatisfy(\.isASCII) }) { delta.nonASCIIFilters += 1 }
            // A filter that used to be un-compilable: the old url-filter carried
            // a disjunction, or the trigger carried a rejected shape.
            if old?.contains("|") == true || options.loadType != nil
                || (!options.domains.isEmpty && !options.notDomains.isEmpty)
            {
                delta.unblockedByFix += 1
            }

            guard let old, let token = token(parsed) else { continue }
            for url in probeURLs(token) {
                let before = matches(old, url)
                let after = new.contains { matches($0, url) }
                if before == after { continue }
                if after {
                    delta.urlsGained += 1
                } else {
                    delta.urlsLost += 1
                    if isBareAuthority(url) { delta.urlsLostOnBareAuthority += 1 }
                }
            }
        }

        print(
            """

            === EasyList delta (issue #134) ===
            lines                      \(delta.lines)
            comments/cosmetics skipped \(delta.ignored)
            blocking filters           \(delta.blocking)
            exception filters          \(delta.exceptions)
            rules emitted before       \(delta.rulesBefore)
            rules emitted after        \(delta.rulesAfter)
            filters WebKit refused     \(delta.unblockedByFix)
              of which $load-type      \(delta.loadTypeFilters)
              of which both conditions \(delta.bothDomainConditions)
            negations genuinely lost   \(delta.negationsGenuinelyLost)
            non-ASCII (still refused)  \(delta.nonASCIIFilters)
            options-only, now skipped  \(delta.optionsOnlyFiltersSkipped)
            probe URLs newly matched   \(delta.urlsGained)
            probe URLs no longer hit   \(delta.urlsLost)
              of which bare authority  \(delta.urlsLostOnBareAuthority)

            """)

        // Every URL that stopped matching must be a bare authority — a spelling
        // WebKit canonicalises away before matching, so nothing real is lost.
        // This is the load-bearing assertion of the whole change.
        XCTAssertEqual(
            delta.urlsLost, delta.urlsLostOnBareAuthority,
            "a rule stopped matching a URL WebKit can actually present")
        XCTAssertEqual(delta.urlsGained, 0, "a rule started matching something it did not before")
        XCTAssertEqual(delta.negationsGenuinelyLost, 0, "a $domain= negation was carving a real hole")
        XCTAssertEqual(delta.nonASCIIFilters, 0, "upstream now ships a non-punycode IDN host")
        XCTAssertGreaterThan(delta.unblockedByFix, 40_000, "the corpus looks unlike EasyList")
        // 220 `.plain` filters emit a second rule each, less the 6 of the 7
        // options-only lines that used to parse as `.plain` and are now
        // skipped outright.
        XCTAssertEqual(
            delta.rulesAfter - delta.rulesBefore, 214,
            "the plain-host pair count changed; re-derive the report")
        // The only rules this change *removes*. Seven is what upstream has
        // today; if it grows, the follow-up in `UBOFilterParser.parse` (emit
        // the ones whose options WebKit can express) has become worth doing.
        XCTAssertEqual(delta.optionsOnlyFiltersSkipped, 7)
    }

    /// The whole thing, through WebKit. Before #134 this was impossible: the
    /// first `||host^` rule took the document down.
    @MainActor
    func testUpstreamEasyListCompilesUnderWebKit() async throws {
        let text = try easyList()
        let chunks = UBORuleListCompiler.compileJSONChunked(from: text)
        XCTAssertGreaterThan(chunks.count, 0)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwave-easylist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try XCTUnwrap(WKContentRuleListStore(url: dir))

        for (index, chunk) in chunks.enumerated() {
            let verdict = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
                store.compileContentRuleList(forIdentifier: "easylist-\(index)", encodedContentRuleList: chunk) {
                    _, error in
                    guard let error = error as NSError? else { return continuation.resume(returning: "ok") }
                    continuation.resume(
                        returning: (error.userInfo[NSHelpAnchorErrorKey] as? String) ?? error.description)
                }
            }
            XCTAssertEqual(verdict, "ok", "WebKit rejected EasyList chunk \(index)")
        }
    }
}
