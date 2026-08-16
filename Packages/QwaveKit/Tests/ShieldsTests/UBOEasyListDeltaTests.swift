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
            // Asked of the compiler's own predicate, not of `new`: a filter
            // with a non-ASCII url-filter now produces no rules at all, so
            // scanning `new` for non-ASCII would be vacuously true (#139).
            if !UBORuleListCompiler.urlFilterIsExpressible(parsed) { delta.nonASCIIFilters += 1 }
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

    // MARK: - Issue #139: the exception path

    /// The pre-#139 exception url-filter, verbatim: the whole `host/path` tail
    /// handed to `anchoredHostRegex` as though it were a host, which put the
    /// optional port group and the authority's `/` *after* the path.
    private func legacyExceptionURLFilter(_ pattern: String) -> String {
        pattern.hasPrefix("||")
            ? UBORuleListCompiler.anchoredHostRegex(host: String(pattern.dropFirst(2)))
            : NSRegularExpression.escapedPattern(for: pattern)
    }

    /// A filter path as a URL actually spells it. `*` is a filter-syntax
    /// wildcard, never a character a server serves, so a probe that leaves it
    /// literal is not a probe of anything real.
    private func realisticPath(_ path: String) -> String {
        path.replacingOccurrences(of: "*", with: "v1")
    }

    /// The URLs an `@@||host/path` exception exists to cover: the shapes a
    /// browser actually requests, with and without a port, over both schemes,
    /// on the host and on a subdomain.
    private func canonicalExceptionProbeURLs(host: String, path: String) -> [String] {
        let path = realisticPath(path)
        return [
            "https://\(host)/\(path)",
            "http://\(host)/\(path)",
            "https://\(host):8443/\(path)",
            "https://cdn.\(host)/\(path)?q=1",
        ]
    }

    /// The URL the misplaced port group kept working by accident: a *further*
    /// path segment supplies the `/` the pattern was demanding, so the tail
    /// `(:[0-9]+)?/` finds one after all.
    ///
    /// This is why the defect was never visible from a match count. Every one
    /// of the path exceptions in upstream EasyList matched *something* before
    /// the fix — just never the URL it was written for.
    private func accidentalExceptionProbeURL(host: String, path: String) -> String {
        "https://\(host)/\(realisticPath(path))/deeper"
    }

    struct ExceptionDelta {
        var exceptions = 0
        /// `@@||host…` — the only shape this change touches.
        var anchored = 0
        /// …of which carry a path, i.e. the rules #139 broke.
        var withAPath = 0
        /// …of which spell that path with a `*`.
        var withAWildcardPath = 0
        /// Anchored exceptions with no path: the pattern must be unchanged.
        var unchangedPatterns = 0
        var changedPatterns = 0
        /// Exception filters that matched none of the URLs they were written
        /// for and now match them: the answer to "how many allowlist entries
        /// were inert".
        var rulesNowLive = 0
        /// …that already covered a canonical URL before the fix.
        var rulesAlreadyLive = 0
        /// …that match none of their own URLs even now. All wildcard paths;
        /// see `testWildcardPathsAreDeadBeforeAndAfter`.
        var rulesStillDead = 0
        /// Filters that matched the accidental URL before, which is why a match
        /// count never revealed the defect.
        var rulesMatchingOnlyByAccident = 0
        var probesGained = 0
        var probesLost = 0
        /// …of which are the accidental URL under a wildcard path.
        var probesLostOnWildcardAccident = 0
    }

    /// What the #139 fix changes, counted against the real upstream list.
    ///
    /// Reported per *rule*, not just per probe URL, because the number that
    /// matters is "how many allowlist entries were inert and are now live".
    func testEasyListExceptionPathDeltaReport() throws {
        let text = try easyList()
        var delta = ExceptionDelta()
        var live: [String] = []
        var lost: [String] = []

        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard case .exception(let pattern, _) = UBOFilterParser.parse(line) else { continue }
            delta.exceptions += 1
            guard pattern.hasPrefix("||") else { continue }
            delta.anchored += 1

            let old = legacyExceptionURLFilter(pattern)
            let new = newURLFilters(.exception(pattern: pattern, options: UBOFilterOptions()))
            guard let newFilter = new.first else { continue }

            let (host, path) = UBORuleListCompiler.splitAnchoredPattern(pattern.dropFirst(2))
            guard let path else {
                // No path: nothing to move the port group past.
                XCTAssertEqual(newFilter, old, "a path-less exception changed: \(line)")
                delta.unchangedPatterns += 1
                continue
            }
            delta.withAPath += 1
            if path.contains("*") { delta.withAWildcardPath += 1 }
            if newFilter == old { delta.unchangedPatterns += 1 } else { delta.changedPatterns += 1 }

            var canonicalBefore = false
            var canonicalAfter = false
            let accidental = accidentalExceptionProbeURL(host: String(host), path: String(path))
            let canonical = canonicalExceptionProbeURLs(host: String(host), path: String(path))
            for url in canonical {
                let before = matches(old, url)
                let after = matches(newFilter, url)
                canonicalBefore = canonicalBefore || before
                canonicalAfter = canonicalAfter || after
                if before == after { continue }
                if after {
                    delta.probesGained += 1
                } else {
                    delta.probesLost += 1
                    lost.append("LOST(canonical) \(line)\n        url: \(url)")
                }
            }
            let accidentalBefore = matches(old, accidental)
            let accidentalAfter = matches(newFilter, accidental)
            if accidentalBefore && !accidentalAfter {
                delta.probesLost += 1
                if path.contains("*") { delta.probesLostOnWildcardAccident += 1 }
                if lost.count < 10 { lost.append("LOST(accidental) \(line)\n        url: \(accidental)") }
            } else if accidentalAfter && !accidentalBefore {
                delta.probesGained += 1
            }
            if accidentalBefore && !canonicalBefore { delta.rulesMatchingOnlyByAccident += 1 }

            switch (canonicalBefore, canonicalAfter) {
            case (false, true):
                delta.rulesNowLive += 1
                if live.count < 12 { live.append("LIVE  \(line)") }
            case (true, _):
                delta.rulesAlreadyLive += 1
            case (false, false):
                delta.rulesStillDead += 1
            }
        }

        print(
            """

            === EasyList delta (issue #139, exception path) ===
            exception filters             \(delta.exceptions)
              of which @@||host…          \(delta.anchored)
              of which carry a path       \(delta.withAPath)
                of which a wildcard path  \(delta.withAWildcardPath)
            url-filter unchanged          \(delta.unchangedPatterns)
            url-filter changed            \(delta.changedPatterns)
            rules inert before, live now  \(delta.rulesNowLive)
            rules already live            \(delta.rulesAlreadyLive)
            rules still dead (wildcards)  \(delta.rulesStillDead)
            rules that matched only the
              accidental deeper-path URL  \(delta.rulesMatchingOnlyByAccident)
            probe URLs newly matched      \(delta.probesGained)
            probe URLs no longer matched  \(delta.probesLost)
              of which wildcard-accident  \(delta.probesLostOnWildcardAccident)

            \(live.joined(separator: "\n"))
            \(lost.joined(separator: "\n"))

            """)

        XCTAssertEqual(
            delta.changedPatterns, delta.withAPath,
            "an exception with a path kept its old url-filter")
        XCTAssertEqual(
            delta.unchangedPatterns, delta.anchored - delta.withAPath,
            "a path-less exception changed")

        // Nothing a rule was written for stops matching. Every loss is the
        // accidental deeper-path URL under a wildcard path, and every one of
        // those rules is dead on its own URL before *and* after — see
        // `testWildcardPathsAreDeadBeforeAndAfter`, which states that
        // separately so this count cannot quietly absorb a real regression.
        XCTAssertEqual(delta.probesLost, delta.probesLostOnWildcardAccident, "a canonical URL stopped matching")
        XCTAssertEqual(delta.rulesStillDead, delta.withAWildcardPath)
        XCTAssertEqual(delta.rulesNowLive, delta.withAPath - delta.withAWildcardPath)
        XCTAssertEqual(delta.rulesAlreadyLive, 0, "a path exception already covered its own URL")
        // …and every path exception *did* match something before, which is the
        // reason a rule count, a compile check, or a "the exception fires"
        // spot-check all looked healthy.
        XCTAssertEqual(delta.rulesMatchingOnlyByAccident, delta.withAPath)
        XCTAssertGreaterThan(delta.withAPath, 400, "the corpus looks unlike EasyList")
    }

    /// The one thing the fix does not improve, stated rather than absorbed.
    ///
    /// `escapeHost` rewrites `*` to `[^.]*`, and the old exception path ran the
    /// whole `host/path` tail through it, so a `*` inside the path became a
    /// wildcard. The path now goes through `escapedPattern`, which keeps `*`
    /// literal — exactly what blocking `.anchoredPath` filters have always
    /// done. That costs no real coverage, because the misplaced port group
    /// made those rules dead on their own URLs anyway; both spellings miss.
    ///
    /// Expressing `*` in a path properly (`[^/]*`, and for blocking filters
    /// too) is a separate change with its own delta, and is not smuggled in
    /// here. This test pins the status quo so it stays visible.
    func testWildcardPathsAreDeadBeforeAndAfter() throws {
        let line = "@@||cdn.example.com/assets/jwplayer-*/jwplayer.js^"
        guard case .exception(let pattern, _) = UBOFilterParser.parse(line) else {
            return XCTFail("expected an exception")
        }
        let old = legacyExceptionURLFilter(pattern)
        let new = try XCTUnwrap(newURLFilters(.exception(pattern: pattern, options: UBOFilterOptions())).first)
        let url = "https://cdn.example.com/assets/jwplayer-8/jwplayer.js"

        XCTAssertFalse(matches(old, url), "the old pattern covered this; the loss would be real")
        XCTAssertFalse(matches(new, url), "wildcard paths now work — update the delta report's cohort")
        // The only URL the old one covered is the accidental one.
        XCTAssertTrue(matches(old, url + "/deeper"))
        XCTAssertFalse(matches(new, url + "/deeper"))
        // Without a `*`, the same rule is live.
        guard case .exception(let plain, _) = UBOFilterParser.parse("@@||cdn.example.com/assets/jwplayer.js^") else {
            return XCTFail("expected an exception")
        }
        let plainNew = try XCTUnwrap(newURLFilters(.exception(pattern: plain, options: UBOFilterOptions())).first)
        XCTAssertTrue(matches(plainNew, "https://cdn.example.com/assets/jwplayer.js"))
        XCTAssertFalse(matches(legacyExceptionURLFilter(plain), "https://cdn.example.com/assets/jwplayer.js"))
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
