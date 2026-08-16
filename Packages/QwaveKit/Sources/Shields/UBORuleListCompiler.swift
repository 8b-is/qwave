import Foundation

/// Compiles uBlock Origin / EasyList / AdGuard filter lists into
/// `WKContentRuleList` JSON (WebKit's content-blocker format).
///
/// Mapping notes:
/// - Blocking filters become rules with `action: block`.
/// - Exceptions (`@@`) become `action: ignore-previous-rules` and are
///   emitted AFTER all blocking rules, so they win (WebKit applies rules in
///   order and `ignore-previous-rules` stops earlier matches).
/// - `$domain=` becomes `if-domain`/`unless-domain`; `$third-party` becomes
///   `load-type: third-party`; resource types map onto `resource-type`.
/// - Cosmetic filters are skipped (WebKit cannot express them).
public enum UBORuleListCompiler {
    /// Maximum rules per compiled list. WebKit caps rule lists; very large
    /// upstream lists are chunked into multiple lists by the updater.
    public static let maxRulesPerList = 50_000

    public static let resourceTypeMap: [String: String] = [
        "script": "script",
        "image": "image",
        "stylesheet": "style-sheet",
        "font": "font",
        "media": "media",
        "raw": "raw",
        "document": "document",
        "xmlhttprequest": "raw",
        "websocket": "raw",
        "other": "raw",
    ]

    /// Escapes a hostname into a URL-filter regex fragment.
    ///
    /// The `\.` → `\.` pass this used to run first was a literal no-op
    /// (identical needle and replacement) that still cost a full NSString
    /// bridge and scan per call; removing it cannot change the result.
    public static func escapeHost(_ host: String) -> String {
        NSRegularExpression.escapedPattern(for: host)
            .replacingOccurrences(of: "\\*", with: "[^.]*")
    }

    /// Regex for `||example.com^`-style rules: any scheme, any subdomains,
    /// boundary after the host (port or path separator).
    ///
    /// The boundary used to be `(/|$)`, which WebKit's content-blocker engine
    /// rejects outright — "Disjunctions are not supported yet" — taking the
    /// whole rule list down with it (issue #134). It is now just `/`, and that
    /// costs nothing: WebKit matches against the *canonical* URL, which always
    /// carries a path separator after the authority. Measured, not assumed —
    /// a request to `http://127.0.0.1:8802` is blocked by a filter requiring
    /// the slash and is NOT blocked by one requiring end-of-string, so the
    /// alternative `$` branch could never have fired here. See
    /// `UBORuleCompilerWebKitAcceptanceTests`.
    public static func anchoredHostRegex(host: String) -> String {
        "^[a-z]+://([^/]+\\.)*\(escapeHost(host))(:[0-9]+)?/"
    }

    /// Regex for a plain `example.com` rule: host appearing anywhere, with
    /// boundary checks.
    ///
    /// Two disjunctions removed, by different arguments:
    ///
    /// - The leading `([^a-z0-9.-]|\.)*` is `[^a-z0-9-]*`. The union of "any
    ///   character that is not a host character" and "a dot" is exactly "any
    ///   character that is not a letter, digit or hyphen", and `(A|B)*` over
    ///   single-character classes is `[A∪B]*`. Same language, character for
    ///   character.
    /// - The trailing `([^a-z0-9.-]|$)` cannot be merged, so the rule is
    ///   emitted **twice** — once ending in the character class, once ending
    ///   in `$` — which is what an alternation under a single action means
    ///   anyway. See `plainHostRegexAtEndOfURL`; `appendRuleJSON` and
    ///   `filter(_:)` both emit the pair.
    public static func plainHostRegex(host: String) -> String {
        "[^a-z0-9-]*\(escapeHost(host))[^a-z0-9.-]"
    }

    /// The second half of `plainHostRegex`: the same rule for a host that ends
    /// the URL, which the `|$` branch used to cover.
    public static func plainHostRegexAtEndOfURL(host: String) -> String {
        "[^a-z0-9-]*\(escapeHost(host))$"
    }

    public static func trigger(
        urlFilter: String,
        options: UBOFilterOptions
    ) -> [String: Any] {
        var trigger: [String: Any] = ["url-filter": urlFilter]
        if !options.resourceTypes.isEmpty {
            // Sorted: Set iteration order varies per process, and the output
            // must be deterministic for golden tests and the content-hash
            // rule-list cache.
            let mapped = Array(Set(options.resourceTypes.compactMap { resourceTypeMap[$0] })).sorted()
            if !mapped.isEmpty {
                trigger["resource-type"] = mapped
            }
        }
        if let loadType = options.loadType {
            // An array, not a string. WebKit reports "Invalid trigger flags
            // array" for the bare string and refuses the whole list (#134);
            // the value it carries is unchanged.
            trigger["load-type"] = [loadType]
        }
        // At most one domain condition: WebKit rejects a trigger carrying both
        // ("A trigger cannot have more than one condition"). `if-domain` wins
        // when the filter has both, because it is the narrower of the two —
        // see `domainConditionLoses` for exactly what that costs.
        if !options.domains.isEmpty {
            trigger["if-domain"] = options.domains
        } else if !options.notDomains.isEmpty {
            trigger["unless-domain"] = options.notDomains
        }
        return trigger
    }

    /// The `~negation`s a `$domain=a|~b` filter loses when `if-domain` wins.
    ///
    /// Dropping them is normally exact rather than approximate: WebKit's
    /// `if-domain` is an exact-match list (a leading `*` is what asks for
    /// subdomains), so restricting the rule to `a` already excludes `b` for
    /// every `b` that is not itself in the positive list. The one case where
    /// something is genuinely lost is `$domain=example.com|~ads.example.com`,
    /// where the negation was carving a hole *inside* a positive entry — and
    /// since `if-domain` does not match subdomains anyway, that hole was never
    /// reachable either. Returns the negations that overlap a positive entry
    /// so the count can be reported rather than assumed to be zero.
    public static func domainConditionLoses(_ options: UBOFilterOptions) -> [String] {
        guard !options.domains.isEmpty, !options.notDomains.isEmpty else { return [] }
        return options.notDomains.filter { negated in
            options.domains.contains { negated == $0 || negated.hasSuffix(".\($0)") }
        }
    }

    public static func rule(urlFilter: String, options: UBOFilterOptions, isException: Bool) -> [String: Any] {
        [
            "trigger": trigger(urlFilter: urlFilter, options: options),
            "action": ["type": isException ? "ignore-previous-rules" : "block"],
        ]
    }

    /// Splits the tail of a `||host/path` pattern at the first `/`.
    ///
    /// `UBOFilterParser` performs exactly this split for blocking filters and
    /// hands back `.anchoredPath(host:path:)`. `.exception` keeps the raw
    /// pattern instead, so the compiler has to redo it — and not redoing it was
    /// the whole of issue #139: passing `host/path` to `anchoredHostRegex` as
    /// though it were a host emitted
    /// `^[a-z]+://([^/]+\.)*host\/path(:[0-9]+)?/`, which asks for a port
    /// *after* the path and a slash after that. No URL is spelled that way, so
    /// every `@@||host/path^` rule compiled cleanly and matched nothing.
    ///
    /// Reference shape is `plainHostRegex`/`anchoredHostRegex`: the port group
    /// belongs to the authority, so it has to be written before the path.
    static func splitAnchoredPattern(_ rest: Substring) -> (host: Substring, path: Substring?) {
        guard let slash = rest.firstIndex(of: "/") else { return (rest, nil) }
        return (rest[..<slash], rest[rest.index(after: slash)...])
    }

    /// Whether a filter's `url-filter` can be written at all.
    ///
    /// WebKit's content-blocker regex parser takes ASCII only; a `url-filter`
    /// carrying any other byte makes it refuse the **whole document**, which is
    /// how the entire list went down in #134. Such a filter is therefore
    /// declined the same way a cosmetic line is — it counts toward `skipped`,
    /// and toward the `inexpressible` sub-count so the omission is reportable
    /// rather than invisible (issue #139). Upstream EasyList spells IDN hosts in
    /// punycode, so the count is 0 today; `UBOEasyListDeltaTests` asserts that.
    ///
    /// Only the `url-filter` is examined. `if-domain`/`unless-domain` are
    /// separate trigger fields with their own encoding and are not this
    /// function's business.
    public static func urlFilterIsExpressible(_ filter: UBOFilter) -> Bool {
        func isASCII(_ value: some StringProtocol) -> Bool { value.utf8.allSatisfy { $0 < 0x80 } }
        switch filter {
        case .ignore:
            return false
        case .hostname(let host, _), .plain(let host, _):
            return isASCII(host)
        case .anchoredPath(let host, let path, _):
            return isASCII(host) && isASCII(path)
        case .substring(let pattern, _), .exception(let pattern, _):
            return isASCII(pattern)
        }
    }

    /// Which of a filter's rules is being emitted. Only `.plain` has two: the
    /// alternation its boundary used to carry cannot be expressed in one
    /// WebKit-acceptable regex, so it becomes two rules with the same action —
    /// which is what an alternation under one action means.
    public enum RuleVariant: Sendable {
        case primary
        /// `.plain` only: the pattern ending the URL, the old `|$` branch.
        case hostAtEndOfURL
    }

    /// The variants `filter` compiles to, in emission order.
    ///
    /// `compileJSON` deliberately does *not* call this — returning an `Array`
    /// per filter cost one malloc per rule, which is 1k of them on the
    /// benchmark corpus and undoes a slice of #133. It branches inline instead
    /// and `UBORuleCompilerEquivalenceTests` diffs the two paths byte for byte,
    /// so they cannot drift apart unnoticed.
    public static func variants(of filter: UBOFilter) -> [RuleVariant] {
        guard urlFilterIsExpressible(filter) else { return [] }
        if case .plain = filter { return [.primary, .hostAtEndOfURL] }
        return [.primary]
    }

    public static func filter(_ filter: UBOFilter, variant: RuleVariant = .primary) -> [String: Any]? {
        guard urlFilterIsExpressible(filter) else { return nil }
        switch filter {
        case .ignore:
            return nil
        case .hostname(let host, let options):
            return rule(urlFilter: anchoredHostRegex(host: host), options: options, isException: false)
        case .plain(let host, let options):
            let regex =
                variant == .primary ? plainHostRegex(host: host) : plainHostRegexAtEndOfURL(host: host)
            return rule(urlFilter: regex, options: options, isException: false)
        case .anchoredPath(let host, let path, let options):
            let regex = "\(anchoredHostRegex(host: host))\(NSRegularExpression.escapedPattern(for: path))"
            return rule(urlFilter: regex, options: options, isException: false)
        case .substring(let pattern, let options):
            return rule(
                urlFilter: NSRegularExpression.escapedPattern(for: pattern), options: options, isException: false)
        case .exception(let pattern, let options):
            let regex: String
            if pattern.hasPrefix("||") {
                // Same shape as `.anchoredPath` above: authority (with its
                // optional port) first, then the path. See `splitAnchoredPattern`.
                let (host, path) = splitAnchoredPattern(pattern.dropFirst(2))
                regex =
                    anchoredHostRegex(host: String(host))
                    + (path.map { NSRegularExpression.escapedPattern(for: String($0)) } ?? "")
            } else {
                regex = NSRegularExpression.escapedPattern(for: pattern)
            }
            return rule(urlFilter: regex, options: options, isException: true)
        }
    }

    /// Compiles raw filter-list text into a content-blocker JSON document.
    /// Returns (json, skippedCount, exceptionCount, inexpressibleCount) —
    /// `skippedCount` counts cosmetic/unsupported lines, and `inexpressible`
    /// is the sub-count of those that were declined for carrying a non-ASCII
    /// `url-filter` (see `urlFilterIsExpressible`). It is broken out because
    /// it is the one class of omission a filter-list author would want to hear
    /// about: nothing in the line looks unsupported.
    ///
    /// The JSON is written straight into one UTF-8 byte buffer rather than
    /// built as `[[String: Any]]` and handed to `JSONSerialization`. The three
    /// phases that dominated allocations — serialization, per-rule dictionaries
    /// with boxed `Any` values, and per-rule regex `String`s — are all gone;
    /// what remains is the parser plus one `String` per line.
    ///
    /// The emitted document is semantically identical to the old one and its
    /// string values are byte-identical (same escaping, same `\/`); the only
    /// difference is that object keys now appear in a **fixed** order instead
    /// of `JSONSerialization`'s hash order. That is a strict improvement:
    /// the old output was not stable across processes, which quietly defeated
    /// the content-hash rule-list cache. `UBORuleCompilerEquivalenceTests`
    /// pins the equivalence against the previous implementation, which
    /// `filter(_:)` still provides.
    public static func compileJSON(from text: String) -> (
        json: String, skipped: Int, exceptions: Int, inexpressible: Int
    ) {
        var out: [UInt8] = []
        var exceptionBytes: [UInt8] = []
        out.reserveCapacity(text.utf8.count * 2 + 2)
        exceptionBytes.reserveCapacity(text.utf8.count / 2 + 1)
        out.append(UInt8(ascii: "["))

        var wroteBlocking = false
        var skipped = 0
        var exceptionCount = 0
        var inexpressible = 0

        // Substrings, not `components(separatedBy:)`: `Character.isNewline`
        // covers exactly `CharacterSet.newlines`, and both the old and the new
        // loop drop empty lines, so the sequence of non-empty lines is the same.
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let parsed = UBOFilterParser.parse(line)
            if case .ignore = parsed {
                skipped += 1
                continue
            }
            // Declined, and counted as such rather than emitted: a non-ASCII
            // url-filter makes WebKit refuse the whole document.
            guard urlFilterIsExpressible(parsed) else {
                skipped += 1
                inexpressible += 1
                continue
            }
            switch parsed {
            case .ignore:
                break  // Unreachable: `continue`d above.
            case .exception:
                if exceptionCount > 0 { exceptionBytes.append(UInt8(ascii: ",")) }
                appendRuleJSON(parsed, variant: .primary, to: &exceptionBytes)
                exceptionCount += 1
            default:
                // One object per variant — `.plain` emits two (see `variants`,
                // which this must stay in step with).
                if wroteBlocking { out.append(UInt8(ascii: ",")) }
                appendRuleJSON(parsed, variant: .primary, to: &out)
                wroteBlocking = true
                if case .plain = parsed {
                    out.append(UInt8(ascii: ","))
                    appendRuleJSON(parsed, variant: .hostAtEndOfURL, to: &out)
                }
            }
        }

        // Exceptions must come after the blocks they override.
        if wroteBlocking && exceptionCount > 0 { out.append(UInt8(ascii: ",")) }
        out.append(contentsOf: exceptionBytes)
        out.append(UInt8(ascii: "]"))
        return (String(decoding: out, as: UTF8.self), skipped, exceptionCount, inexpressible)
    }

    // MARK: - Direct JSON emission
    //
    // Everything below writes the same document `JSONSerialization` produced
    // for `rule(urlFilter:options:isException:)`, one UTF-8 byte at a time and
    // without allocating. Each helper is pinned to its dictionary-building
    // counterpart above by `UBORuleCompilerEquivalenceTests`.

    /// The distinct `resource-type` values, alphabetically — the order
    /// `Array(Set(...)).sorted()` yields in `trigger(_:)`. Indices are the bit
    /// positions used by `resourceTypeBit(_:)`.
    static let sortedResourceTypes = [
        "document", "font", "image", "media", "raw", "script", "style-sheet",
    ]

    /// `resourceTypeMap` as a bit position, so a rule's resource types can be
    /// collected and emitted in sorted order without a Set or an Array.
    /// `UBORuleCompilerEquivalenceTests.testResourceTypeBitsMatchTheMap` fails
    /// if this and `resourceTypeMap` ever drift apart.
    static func resourceTypeBit(_ token: String) -> UInt8 {
        switch token {
        case "document": return 1 << 0
        case "font": return 1 << 1
        case "image": return 1 << 2
        case "media": return 1 << 3
        case "raw", "xmlhttprequest", "websocket", "other": return 1 << 4
        case "script": return 1 << 5
        case "stylesheet": return 1 << 6
        default: return 0  // Unsupported type: `compactMap` dropped it too.
        }
    }

    /// The characters `NSRegularExpression.escapedPattern(for:)` prefixes with
    /// a backslash. Measured exhaustively over ASCII; it leaves `]`, `-`, and
    /// every non-ASCII scalar alone. Only ASCII is tested here, which is safe
    /// because every byte of a multi-byte UTF-8 sequence is >= 0x80.
    static func isRegexMeta(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "$"), UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "*"),
            UInt8(ascii: "+"), UInt8(ascii: "."), UInt8(ascii: "/"), UInt8(ascii: "?"),
            UInt8(ascii: "["), UInt8(ascii: "\\"), UInt8(ascii: "^"), UInt8(ascii: "{"),
            UInt8(ascii: "|"), UInt8(ascii: "}"):
            return true
        default:
            return false
        }
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    /// Appends one byte the way `JSONSerialization` escapes it: the five named
    /// escapes, `"`, `\`, and — the non-obvious one — `/` as `\/`; any other
    /// C0 control as `\u00xx` with lowercase hex; everything else, DEL and all
    /// non-ASCII included, verbatim.
    static func appendJSONEscaped(_ byte: UInt8, to out: inout [UInt8]) {
        switch byte {
        case UInt8(ascii: "\""): out.append(UInt8(ascii: "\\")); out.append(UInt8(ascii: "\""))
        case UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\")); out.append(UInt8(ascii: "\\"))
        case UInt8(ascii: "/"): out.append(UInt8(ascii: "\\")); out.append(UInt8(ascii: "/"))
        case 0x08: out.append(UInt8(ascii: "\\")); out.append(UInt8(ascii: "b"))
        case 0x09: out.append(UInt8(ascii: "\\")); out.append(UInt8(ascii: "t"))
        case 0x0A: out.append(UInt8(ascii: "\\")); out.append(UInt8(ascii: "n"))
        case 0x0C: out.append(UInt8(ascii: "\\")); out.append(UInt8(ascii: "f"))
        case 0x0D: out.append(UInt8(ascii: "\\")); out.append(UInt8(ascii: "r"))
        case 0x00..<0x20:
            out.append(UInt8(ascii: "\\"))
            out.append(UInt8(ascii: "u"))
            out.append(UInt8(ascii: "0"))
            out.append(UInt8(ascii: "0"))
            out.append(hexDigits[Int(byte >> 4)])
            out.append(hexDigits[Int(byte & 0x0F)])
        default: out.append(byte)
        }
    }

    static func appendJSONString<S: StringProtocol>(_ value: S, to out: inout [UInt8]) {
        for byte in value.utf8 { appendJSONEscaped(byte, to: &out) }
    }

    /// `NSRegularExpression.escapedPattern(for:)`, JSON-escaped in the same
    /// pass — what `escapedPattern` produced and `JSONSerialization` then
    /// encoded, without the two intermediate `String`s.
    static func appendRegexEscaped<S: StringProtocol>(_ value: S, to out: inout [UInt8]) {
        for byte in value.utf8 {
            if isRegexMeta(byte) {
                // The regex's own backslash, JSON-escaped.
                out.append(UInt8(ascii: "\\"))
                out.append(UInt8(ascii: "\\"))
            }
            appendJSONEscaped(byte, to: &out)
        }
    }

    /// `escapeHost(_:)`, JSON-escaped in the same pass.
    ///
    /// `escapeHost` escapes the host and then rewrites `\*` to `[^.]*`. Since
    /// `escapedPattern` always escapes `*`, and its output is a sequence of
    /// tokens that are each one bare character or a backslash pair, every `\*`
    /// a left-to-right search can find is exactly one escaped `*` — so
    /// translating `*` directly is the same rewrite.
    static func appendEscapedHost<S: StringProtocol>(_ host: S, to out: inout [UInt8]) {
        for byte in host.utf8 {
            if byte == UInt8(ascii: "*") {
                out.append(contentsOf: "[^.]*".utf8)
            } else if isRegexMeta(byte) {
                out.append(UInt8(ascii: "\\"))
                out.append(UInt8(ascii: "\\"))
                appendJSONEscaped(byte, to: &out)
            } else {
                appendJSONEscaped(byte, to: &out)
            }
        }
    }

    /// `anchoredHostRegex(host:)`, JSON-escaped. The literal halves are
    /// pre-escaped: `//` and the `\.` in the subdomain group.
    private static func appendAnchoredHostRegex<S: StringProtocol>(_ host: S, to out: inout [UInt8]) {
        out.append(contentsOf: #"^[a-z]+:\/\/([^\/]+\\.)*"#.utf8)
        appendEscapedHost(host, to: &out)
        out.append(contentsOf: #"(:[0-9]+)?\/"#.utf8)
    }

    /// `plainHostRegex(host:)`, JSON-escaped.
    private static func appendPlainHostRegex<S: StringProtocol>(_ host: S, to out: inout [UInt8]) {
        out.append(contentsOf: #"[^a-z0-9-]*"#.utf8)
        appendEscapedHost(host, to: &out)
        out.append(contentsOf: #"[^a-z0-9.-]"#.utf8)
    }

    /// `plainHostRegexAtEndOfURL(host:)`, JSON-escaped.
    private static func appendPlainHostRegexAtEndOfURL<S: StringProtocol>(_ host: S, to out: inout [UInt8]) {
        out.append(contentsOf: #"[^a-z0-9-]*"#.utf8)
        appendEscapedHost(host, to: &out)
        out.append(UInt8(ascii: "$"))
    }

    /// Appends the JSON object for one rule. Keys are written in a fixed
    /// order; `filter(_:)` remains the reference the tests diff against.
    private static func appendRuleJSON(_ parsed: UBOFilter, variant: RuleVariant, to out: inout [UInt8]) {
        if case .ignore = parsed { return }

        out.append(contentsOf: #"{"trigger":{"url-filter":""#.utf8)
        var options = UBOFilterOptions()
        var isException = false
        switch parsed {
        case .ignore:
            break  // Unreachable: returned above.
        case .hostname(let host, let opts):
            options = opts
            appendAnchoredHostRegex(host, to: &out)
        case .plain(let host, let opts):
            options = opts
            if variant == .primary {
                appendPlainHostRegex(host, to: &out)
            } else {
                appendPlainHostRegexAtEndOfURL(host, to: &out)
            }
        case .anchoredPath(let host, let path, let opts):
            options = opts
            appendAnchoredHostRegex(host, to: &out)
            appendRegexEscaped(path, to: &out)
        case .substring(let pattern, let opts):
            options = opts
            appendRegexEscaped(pattern, to: &out)
        case .exception(let pattern, let opts):
            options = opts
            isException = true
            if pattern.hasPrefix("||") {
                // Authority first, then the path — the `.anchoredPath` shape.
                // Writing the path inside `appendAnchoredHostRegex`'s host
                // argument put the port group after it (#139).
                let (host, path) = splitAnchoredPattern(pattern.dropFirst(2))
                appendAnchoredHostRegex(host, to: &out)
                if let path { appendRegexEscaped(path, to: &out) }
            } else {
                appendRegexEscaped(pattern, to: &out)
            }
        }
        out.append(UInt8(ascii: "\""))

        if !options.resourceTypes.isEmpty {
            var mask: UInt8 = 0
            for type in options.resourceTypes { mask |= resourceTypeBit(type) }
            if mask != 0 {
                out.append(contentsOf: #","resource-type":["#.utf8)
                var first = true
                for (index, name) in sortedResourceTypes.enumerated() where mask & (1 << index) != 0 {
                    if !first { out.append(UInt8(ascii: ",")) }
                    first = false
                    out.append(UInt8(ascii: "\""))
                    out.append(contentsOf: name.utf8)
                    out.append(UInt8(ascii: "\""))
                }
                out.append(UInt8(ascii: "]"))
            }
        }
        if let loadType = options.loadType {
            out.append(contentsOf: #","load-type":[""#.utf8)
            appendJSONString(loadType, to: &out)
            out.append(contentsOf: #""]"#.utf8)
        }
        // One condition only — see `trigger(urlFilter:options:)`.
        if !options.domains.isEmpty {
            appendDomainList(options.domains, key: #","if-domain":["#, to: &out)
        } else {
            appendDomainList(options.notDomains, key: #","unless-domain":["#, to: &out)
        }

        out.append(contentsOf: #"},"action":{"type":""#.utf8)
        out.append(contentsOf: (isException ? "ignore-previous-rules" : "block").utf8)
        out.append(contentsOf: #""}}"#.utf8)
    }

    private static func appendDomainList(_ domains: [String], key: String, to out: inout [UInt8]) {
        guard !domains.isEmpty else { return }
        out.append(contentsOf: key.utf8)
        for (index, domain) in domains.enumerated() {
            if index > 0 { out.append(UInt8(ascii: ",")) }
            out.append(UInt8(ascii: "\""))
            appendJSONString(domain, to: &out)
            out.append(UInt8(ascii: "\""))
        }
        out.append(UInt8(ascii: "]"))
    }

    /// Splits very large lists into chunks of `maxRulesPerList` rules so the
    /// WebKit compiler never sees an oversized document.
    public static func compileJSONChunked(from text: String) -> [String] {
        var chunks: [String] = []
        var current: [String] = []
        var buffer: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            buffer.append(line)
            if buffer.count >= maxRulesPerList {
                current.append(buffer.joined(separator: "\n"))
                buffer = []
            }
        }
        if !buffer.isEmpty {
            current.append(buffer.joined(separator: "\n"))
        }
        for chunk in current {
            chunks.append(compileJSON(from: chunk).json)
        }
        return chunks
    }
}
