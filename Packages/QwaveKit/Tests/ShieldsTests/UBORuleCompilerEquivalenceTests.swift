import XCTest
import WebKit

@testable import Shields

/// Pins the byte-buffer JSON emitter in `UBORuleListCompiler.compileJSON` to
/// the `[String: Any]` + `JSONSerialization` implementation it replaced.
///
/// `filter(_:)`, `rule(_:)` and `trigger(_:)` are still the old code path, so
/// `reference(from:)` below is a faithful copy of the previous `compileJSON`
/// body and every test here is a real differential, not a restatement of the
/// new implementation.
///
/// The one intended difference is key ORDER: `JSONSerialization` emitted
/// object keys in hash order (`resource-type` before `url-filter`, and not
/// even stably across processes), the emitter writes a fixed order. Equality
/// is therefore asserted on both documents re-serialized with `.sortedKeys`,
/// which compares the decoded structures — rule count, rule order, key set,
/// and every value — and is blind only to key order.
final class UBORuleCompilerEquivalenceTests: XCTestCase {

    // MARK: - The previous implementation, verbatim

    private func reference(from text: String) -> (json: String, skipped: Int, exceptions: Int) {
        var blockingRules: [[String: Any]] = []
        var exceptionRules: [[String: Any]] = []
        var skipped = 0

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let parsed = UBOFilterParser.parse(line)
            switch parsed {
            case .ignore:
                skipped += 1
            case .exception:
                if let rule = UBORuleListCompiler.filter(parsed) {
                    exceptionRules.append(rule)
                } else {
                    skipped += 1
                }
            default:
                // One rule per variant. Before #134 there was always exactly
                // one; `.plain` now emits two because the boundary alternation
                // WebKit rejects has to become two rules under one action.
                let rules = UBORuleListCompiler.variants(of: parsed)
                    .compactMap { UBORuleListCompiler.filter(parsed, variant: $0) }
                if rules.isEmpty {
                    skipped += 1
                } else {
                    blockingRules.append(contentsOf: rules)
                }
            }
        }

        let rules = blockingRules + exceptionRules
        let data = try! JSONSerialization.data(withJSONObject: rules)
        return (String(data: data, encoding: .utf8) ?? "[]", skipped, exceptionRules.count)
    }

    private func normalized(_ json: String) throws -> String {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func assertEquivalent(_ text: String, _ label: String, file: StaticString = #filePath, line: UInt = #line)
        throws
    {
        let new = UBORuleListCompiler.compileJSON(from: text)
        let old = reference(from: text)
        XCTAssertEqual(new.skipped, old.skipped, "\(label): skipped count", file: file, line: line)
        XCTAssertEqual(new.exceptions, old.exceptions, "\(label): exception count", file: file, line: line)
        XCTAssertEqual(
            try normalized(new.json), try normalized(old.json),
            "\(label): decoded document differs", file: file, line: line)
    }

    /// A string as `JSONSerialization` encodes it, quotes stripped — the raw
    /// bytes the emitter has to reproduce.
    private func jsonEncoded(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [value])
        var text = String(decoding: data, as: UTF8.self)  // ["…"]
        text.removeFirst(2)
        text.removeLast(2)
        return text
    }

    private func emitted(_ body: (inout [UInt8]) -> Void) -> String {
        var buffer: [UInt8] = []
        body(&buffer)
        return String(decoding: buffer, as: UTF8.self)
    }

    // MARK: - Corpora

    /// Every shape the parser can take, including the ones that are easy to
    /// get wrong: comments, cosmetics, malformed options, wildcards, `|`
    /// anchors, regex-looking literals, non-ASCII hosts, CRLF, and lines that
    /// are only whitespace.
    static let nastyCorpus = """
        [Adblock Plus 2.0]
        ! Title: fixture
        !
        # hosts-style comment
        ||ads.example.com^
        ||tracker.example.com^$third-party
        ||cdn.example.com/banner.js^$image,script
        ||metrics.example.com^$domain=news.example|~blog.news.example
        ||wild*card.example.com^
        ||back\\slash.example^
        ||dots...example.com^
        ||port.example.com^$first-party
        ||all.example^$script,image,stylesheet,font,media,raw,document,xmlhttprequest,websocket,other
        ||dup.example^$raw,xmlhttprequest,websocket,other
        ||unsupported.example^$removeparam=utm_source
        ||bare.example^$domain
        ||empty.example^$
        ||caret.example.com^/path/with^caret
        ||regexy.example.com/a+b(c)[d]{e}|f?g.h*i^
        ||üñïçøde.example^
        ||xn--bcher-kva.example^
        beacon.example.net
        plain-with-dash.example
        /analytics/track.js
        /ads/(banner|leaderboard).gif
        |http://anchored.example/x
        example.com/path/no-anchor
        @@||allowed.example.com^
        @@||allowed.example.com/path^$script
        @@/not-anchored/allow.js
        @@||exempt.example^$domain=trusted.example
        example.com##.ad-slot
        example.com#@#.ad-slot
        example.com#?#div:has(> .ad)
        ||trailing.example^\u{0020}\u{0009}
        \u{0020}\u{0009}
        ||crlf.example^\r
        ||tab\tinside.example^
        ||quote".example^
        """

    static func generatedCorpus(_ count: Int) -> String {
        (0..<count).map { index -> String in
            switch index % 7 {
            case 0: return "||ads\(index).example.com^"
            case 1: return "||tracker\(index).example.com^$third-party"
            case 2: return "||cdn\(index).example.com/banner^$image,script"
            case 3: return "@@||allowed\(index).example.com^"
            case 4: return "||dom\(index).example^$domain=a\(index).test|~b\(index).test"
            case 5: return "! comment \(index)"
            default: return "sub\(index).example.net/track.js"
            }
        }.joined(separator: "\n")
    }

    // MARK: - Differential over corpora

    func testEquivalentOnNastyCorpus() throws {
        try assertEquivalent(Self.nastyCorpus, "nasty corpus")
    }

    func testEquivalentOnGeneratedCorpus() throws {
        try assertEquivalent(Self.generatedCorpus(2_000), "generated corpus")
    }

    func testEquivalentOnEdgeCaseInputs() throws {
        for (index, text) in [
            "", "\n", "\r\n", "   ", "\n\n\n", "!", "@@", "||", "^", "$",
            "||only.example^", "@@||only.example^",
            "! comment only\n! another",
            "||a^\n@@||b^\n||c^\n@@||d^",
        ].enumerated() {
            try assertEquivalent(text, "edge case #\(index)")
        }
    }

    /// The real shipped Safe Browsing list, run through the uBO parser. It is
    /// hosts syntax, so it exercises the `.plain` and `.ignore` paths on data
    /// that actually ships.
    func testEquivalentOnShippedMaliciousHostsList() throws {
        try assertEquivalent(try HostsRuleListCompiler.bundledSource(), "malicious-hosts.txt")
    }

    /// Runs the differential over a full upstream EasyList when one is
    /// available, which is what `RemoteBlocklistUpdater` actually feeds this
    /// compiler. The file is not committed (it is CC BY-SA and ~3 MB), so the
    /// test skips unless `QWAVE_EASYLIST_PATH` points at one:
    ///
    ///     curl -o /tmp/easylist.txt https://easylist.to/easylist/easylist.txt
    ///     QWAVE_EASYLIST_PATH=/tmp/easylist.txt swift test …
    func testEquivalentOnUpstreamEasyListIfAvailable() throws {
        guard let path = ProcessInfo.processInfo.environment["QWAVE_EASYLIST_PATH"] else {
            throw XCTSkip("set QWAVE_EASYLIST_PATH to diff against a real upstream list")
        }
        try assertEquivalent(String(contentsOfFile: path, encoding: .utf8), "upstream EasyList")
    }

    // MARK: - The assumptions the emitter is built on

    /// The emitter hard-codes which characters `escapedPattern` backslashes.
    /// If a toolchain ever changes that set, this fails before any output does.
    func testRegexMetaSetMatchesEscapedPattern() {
        func check(_ scalar: Unicode.Scalar) {
            let text = String(scalar)
            let escaped = NSRegularExpression.escapedPattern(for: text)
            let expected = scalar.isASCII && UBORuleListCompiler.isRegexMeta(UInt8(scalar.value))
            XCTAssertEqual(
                escaped != text, expected,
                "U+\(String(scalar.value, radix: 16, uppercase: true)): escapedPattern gave \(escaped)")
            if expected {
                XCTAssertEqual(escaped, "\\" + text)
            }
        }
        for value in 0...0xFFFF where !(0xD800...0xDFFF).contains(value) {
            check(Unicode.Scalar(UInt32(value))!)
        }
        // Sample the supplementary planes rather than walking a million scalars.
        for value in stride(from: 0x10000, through: 0x10FFFF, by: 97) {
            check(Unicode.Scalar(UInt32(value))!)
        }
    }

    /// `escapeHost` lost a `\.` → `\.` pass. Prove it was an identity.
    func testEscapeHostMatchesTheOriginalTwoPassForm() {
        for host in [
            "example.com", "a*b.example", "*.example", "**", "\\", "\\*", "\\\\*", "\\\\\\*",
            "a.b-c_d~e", "üñïçøde.example", "[]{}()^$+?|/", "", ".", "*", "a\\*b", "😀.example",
        ] {
            let original = NSRegularExpression.escapedPattern(for: host)
                .replacingOccurrences(of: "\\.", with: "\\.")
                .replacingOccurrences(of: "\\*", with: "[^.]*")
            XCTAssertEqual(UBORuleListCompiler.escapeHost(host), original, "host: \(host)")
        }
    }

    func testAppendEscapedHostMatchesEscapeHostThroughJSON() throws {
        for host in [
            "example.com", "a*b.example", "*.example", "\\", "\\*", "a\"b", "a/b", "tab\tb",
            "üñïçøde.example", "😀.example", "nul\u{0}x", "vt\u{0B}x", "del\u{7F}x", "[]{}()^$+?|",
        ] {
            let expected = try jsonEncoded(UBORuleListCompiler.escapeHost(host))
            let actual = emitted { UBORuleListCompiler.appendEscapedHost(host, to: &$0) }
            XCTAssertEqual(actual, expected, "host: \(host)")
        }
    }

    func testAppendRegexEscapedMatchesEscapedPatternThroughJSON() throws {
        for value in [
            "/ads/banner.js", "a+b(c)[d]{e}|f?g.h*i", "\\", "\"", "a/b", "\n\r\t",
            "üñïçøde", "😀", "\u{0}\u{1F}\u{7F}", "",
        ] {
            let expected = try jsonEncoded(NSRegularExpression.escapedPattern(for: value))
            let actual = emitted { UBORuleListCompiler.appendRegexEscaped(value, to: &$0) }
            XCTAssertEqual(actual, expected, "value: \(value)")
        }
    }

    /// The plain string escaper — used for `load-type` and the domain lists —
    /// must reproduce `JSONSerialization` byte for byte, including its
    /// non-obvious `\/` and its lowercase `\u00xx` controls.
    func testAppendJSONStringMatchesJSONSerialization() throws {
        var values = [
            "a\"b\\c/d\u{08}e\u{0C}f\ng\rh\ti\u{0}j\u{1F}k\u{7F}l£m😀n\u{2028}o\u{A0}p",
            "", "plain.example", "-", "\u{2029}",
        ]
        for value in 0...0x10F { values.append("x\(Unicode.Scalar(UInt32(value))!)y") }
        for value in values {
            let expected = try jsonEncoded(value)
            let actual = emitted { UBORuleListCompiler.appendJSONString(value, to: &$0) }
            XCTAssertEqual(actual, expected, "value: \(value.debugDescription)")
        }
    }

    /// The resource-type bitmask is a second encoding of `resourceTypeMap`.
    func testResourceTypeBitsMatchTheMap() {
        XCTAssertEqual(
            UBORuleListCompiler.sortedResourceTypes,
            Set(UBORuleListCompiler.resourceTypeMap.values).sorted())
        for (token, mapped) in UBORuleListCompiler.resourceTypeMap {
            let bit = UBORuleListCompiler.resourceTypeBit(token)
            let index = try? XCTUnwrap(UBORuleListCompiler.sortedResourceTypes.firstIndex(of: mapped))
            XCTAssertEqual(bit, UInt8(1) << UInt8(index ?? 99), "token: \(token)")
        }
        XCTAssertEqual(UBORuleListCompiler.resourceTypeBit("popup"), 0)
        XCTAssertEqual(UBORuleListCompiler.resourceTypeBit(""), 0)
    }

    // MARK: - Output stability and WebKit acceptance

    /// The old output's key order came from `JSONSerialization`'s hashing and
    /// was not guaranteed stable; the emitter's is fixed. The content-hash
    /// rule-list cache depends on this.
    func testOutputIsByteStableAcrossCalls() {
        let first = UBORuleListCompiler.compileJSON(from: Self.nastyCorpus).json
        for _ in 0..<5 {
            XCTAssertEqual(UBORuleListCompiler.compileJSON(from: Self.nastyCorpus).json, first)
        }
    }

    /// Compiles `json` through WebKit and reports its verdict.
    @MainActor
    private func webKitVerdict(_ json: String, identifier: String) async -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwave-ubo-equiv-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let store = WKContentRuleListStore(url: dir) else { return "no store" }
        return await withCheckedContinuation { continuation in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { _, error in
                guard let error = error as NSError? else { return continuation.resume(returning: "ok") }
                continuation.resume(returning: (error.userInfo[NSHelpAnchorErrorKey] as? String) ?? error.description)
            }
        }
    }

    /// Nothing compiled this compiler's own output through WebKit before:
    /// `RuleListCompileTests` only checks the bundled pre-compiled snapshot,
    /// which AdGuard's converter produces, not this code. That gap is why the
    /// findings recorded in `testWebKitRejectsTheSameRuleShapesAsBefore` went
    /// unnoticed.
    ///
    /// This is the part that guards the change made here: for the rule shapes
    /// WebKit does accept, the emitted document — its syntax, its `\/`
    /// escaping, its regex backslashes — must survive WebKit's real parser.
    @MainActor
    func testEmittedDocumentIsAcceptedByWebKit() async throws {
        let list = """
            [Adblock Plus 2.0]
            ! fixture
            /analytics/track.js
            /ads/banner.gif
            @@/analytics/allowed.js
            example.com##.ad-slot
            """
        let (json, _, _) = UBORuleListCompiler.compileJSON(from: list)
        let verdict = await webKitVerdict(json, identifier: "emitted")
        XCTAssertEqual(verdict, "ok", "WebKit rejected the emitted document: \(json)")
    }

    /// The differential's WebKit half: whatever WebKit says about the emitter's
    /// output, it says about the dictionary path's output too.
    ///
    /// Until #134 that agreement was on *rejection* — the three shapes the
    /// issue lists ("Disjunctions are not supported yet", "Invalid trigger
    /// flags array", "a trigger cannot have more than one condition") came out
    /// of both implementations alike. Both are fixed, so the agreement is now
    /// on acceptance, which `testBothImplementationsCompileUnderWebKit` below
    /// states directly. This test keeps checking the *equality*, which is the
    /// part that belongs to #133 and holds either way.
    @MainActor
    func testWebKitGivesTheSameVerdictForBothImplementations() async throws {
        for (index, line) in [
            "||ads.example.com^",
            "||tracker.example.com^$third-party",
            "||cdn.example.com/banner.js^$image,script",
            "||metrics.example.com^$domain=news.example|~blog.news.example",
            "beacon.example.net",
            "/analytics/track.js",
            "@@||allowed.example.com^",
            "@@/analytics/allowed.js",
        ].enumerated() {
            let new = await webKitVerdict(UBORuleListCompiler.compileJSON(from: line).json, identifier: "new\(index)")
            let old = await webKitVerdict(reference(from: line).json, identifier: "old\(index)")
            XCTAssertEqual(new, old, "WebKit verdict changed for: \(line)")
        }
    }

    /// The half of the statement above that #134 changes: the shared verdict is
    /// now "ok". Separate from the equality check so a regression names which
    /// of the two properties broke.
    @MainActor
    func testBothImplementationsCompileUnderWebKit() async throws {
        for (index, line) in [
            "||ads.example.com^",
            "||tracker.example.com^$third-party",
            "||cdn.example.com/banner.js^$image,script",
            "||metrics.example.com^$domain=news.example|~blog.news.example",
            "beacon.example.net",
            "/analytics/track.js",
            "@@||allowed.example.com^",
            "@@/analytics/allowed.js",
        ].enumerated() {
            let json = UBORuleListCompiler.compileJSON(from: line).json
            let new = await webKitVerdict(json, identifier: "ok-new\(index)")
            XCTAssertEqual(new, "ok", "emitter output rejected for: \(line)")
            let old = await webKitVerdict(reference(from: line).json, identifier: "ok-old\(index)")
            XCTAssertEqual(old, "ok", "dictionary-path output rejected for: \(line)")
        }
    }
}
