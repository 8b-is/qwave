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
    public static func anchoredHostRegex(host: String) -> String {
        "^[a-z]+://([^/]+\\.)*\(escapeHost(host))(:[0-9]+)?(/|$)"
    }

    /// Regex for a plain `example.com` rule: host appearing anywhere, with
    /// boundary checks.
    public static func plainHostRegex(host: String) -> String {
        "([^a-z0-9.-]|\\.)*\(escapeHost(host))([^a-z0-9.-]|$)"
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
            trigger["load-type"] = loadType
        }
        if !options.domains.isEmpty {
            trigger["if-domain"] = options.domains
        }
        if !options.notDomains.isEmpty {
            trigger["unless-domain"] = options.notDomains
        }
        return trigger
    }

    public static func rule(urlFilter: String, options: UBOFilterOptions, isException: Bool) -> [String: Any] {
        [
            "trigger": trigger(urlFilter: urlFilter, options: options),
            "action": ["type": isException ? "ignore-previous-rules" : "block"],
        ]
    }

    public static func filter(_ filter: UBOFilter) -> [String: Any]? {
        switch filter {
        case .ignore:
            return nil
        case .hostname(let host, let options):
            return rule(urlFilter: anchoredHostRegex(host: host), options: options, isException: false)
        case .plain(let host, let options):
            return rule(urlFilter: plainHostRegex(host: host), options: options, isException: false)
        case .anchoredPath(let host, let path, let options):
            let regex = "\(anchoredHostRegex(host: host))\(NSRegularExpression.escapedPattern(for: path))"
            return rule(urlFilter: regex, options: options, isException: false)
        case .substring(let pattern, let options):
            return rule(
                urlFilter: NSRegularExpression.escapedPattern(for: pattern), options: options, isException: false)
        case .exception(let pattern, let options):
            let regex: String
            if pattern.hasPrefix("||") {
                regex = anchoredHostRegex(host: String(pattern.dropFirst(2)))
            } else {
                regex = NSRegularExpression.escapedPattern(for: pattern)
            }
            return rule(urlFilter: regex, options: options, isException: true)
        }
    }

    /// Compiles raw filter-list text into a content-blocker JSON document.
    /// Returns (json, skippedCount, exceptionCount) — `skippedCount` counts
    /// cosmetic/unsupported lines.
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
    public static func compileJSON(from text: String) -> (json: String, skipped: Int, exceptions: Int) {
        var out: [UInt8] = []
        var exceptionBytes: [UInt8] = []
        out.reserveCapacity(text.utf8.count * 2 + 2)
        exceptionBytes.reserveCapacity(text.utf8.count / 2 + 1)
        out.append(UInt8(ascii: "["))

        var wroteBlocking = false
        var skipped = 0
        var exceptionCount = 0

        // Substrings, not `components(separatedBy:)`: `Character.isNewline`
        // covers exactly `CharacterSet.newlines`, and both the old and the new
        // loop drop empty lines, so the sequence of non-empty lines is the same.
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let parsed = UBOFilterParser.parse(line)
            switch parsed {
            case .ignore:
                skipped += 1
            case .exception:
                if exceptionCount > 0 { exceptionBytes.append(UInt8(ascii: ",")) }
                appendRuleJSON(parsed, to: &exceptionBytes)
                exceptionCount += 1
            default:
                if wroteBlocking { out.append(UInt8(ascii: ",")) }
                appendRuleJSON(parsed, to: &out)
                wroteBlocking = true
            }
        }

        // Exceptions must come after the blocks they override.
        if wroteBlocking && exceptionCount > 0 { out.append(UInt8(ascii: ",")) }
        out.append(contentsOf: exceptionBytes)
        out.append(UInt8(ascii: "]"))
        return (String(decoding: out, as: UTF8.self), skipped, exceptionCount)
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
        out.append(contentsOf: #"(:[0-9]+)?(\/|$)"#.utf8)
    }

    /// `plainHostRegex(host:)`, JSON-escaped.
    private static func appendPlainHostRegex<S: StringProtocol>(_ host: S, to out: inout [UInt8]) {
        out.append(contentsOf: #"([^a-z0-9.-]|\\.)*"#.utf8)
        appendEscapedHost(host, to: &out)
        out.append(contentsOf: #"([^a-z0-9.-]|$)"#.utf8)
    }

    /// Appends the JSON object for one rule. Keys are written in a fixed
    /// order; `filter(_:)` remains the reference the tests diff against.
    private static func appendRuleJSON(_ parsed: UBOFilter, to out: inout [UInt8]) {
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
            appendPlainHostRegex(host, to: &out)
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
                appendAnchoredHostRegex(pattern.dropFirst(2), to: &out)
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
            out.append(contentsOf: #","load-type":""#.utf8)
            appendJSONString(loadType, to: &out)
            out.append(UInt8(ascii: "\""))
        }
        appendDomainList(options.domains, key: #","if-domain":["#, to: &out)
        appendDomainList(options.notDomains, key: #","unless-domain":["#, to: &out)

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
