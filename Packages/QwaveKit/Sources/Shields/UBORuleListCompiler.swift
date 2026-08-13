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
    public static func escapeHost(_ host: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: host)
        return escaped.replacingOccurrences(of: "\\.", with: "\\.")
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
            return rule(urlFilter: NSRegularExpression.escapedPattern(for: pattern), options: options, isException: false)
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
    public static func compileJSON(from text: String) -> (json: String, skipped: Int, exceptions: Int) {
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
                if let rule = filter(parsed) {
                    exceptionRules.append(rule)
                } else {
                    skipped += 1
                }
            default:
                if let rule = filter(parsed) {
                    blockingRules.append(rule)
                } else {
                    skipped += 1
                }
            }
        }

        // Exceptions must come after the blocks they override.
        let rules = blockingRules + exceptionRules
        let data = try! JSONSerialization.data(withJSONObject: rules)
        return (String(data: data, encoding: .utf8) ?? "[]", skipped, exceptionRules.count)
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
