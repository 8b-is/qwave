import Foundation

/// A single parsed uBlock Origin / AdGuard network filter line.
public enum UBOFilter: Equatable, Sendable {
    /// `||example.com^` — block requests to example.com and subdomains.
    case hostname(host: String, options: UBOFilterOptions)
    /// `example.com` — block requests whose URL contains this host.
    case plain(host: String, options: UBOFilterOptions)
    /// `||example.com/path^` — block requests matching the anchored path.
    case anchoredPath(host: String, path: String, options: UBOFilterOptions)
    /// `example.com/path` — substring match.
    case substring(pattern: String, options: UBOFilterOptions)
    /// `@@...` — exception; compiled to `ignore-previous-rules`.
    case exception(pattern: String, options: UBOFilterOptions)
    /// Comments (`!`, `#`, `[Adblock Plus]`) and unsupported syntax.
    case ignore
}

public struct UBOFilterOptions: Equatable, Sendable {
    /// `$script,image,stylesheet,...`
    public var resourceTypes: Set<String>
    /// `$third-party` / `$first-party`
    public var loadType: String?
    /// `$domain=example.com|~sub.example.com`
    public var domains: [String]
    /// `$~domain=...` (negated)
    public var notDomains: [String]

    public init(
        resourceTypes: Set<String> = [],
        loadType: String? = nil,
        domains: [String] = [],
        notDomains: [String] = []
    ) {
        self.resourceTypes = resourceTypes
        self.loadType = loadType
        self.domains = domains
        self.notDomains = notDomains
    }

    public var isEmpty: Bool {
        resourceTypes.isEmpty && loadType == nil && domains.isEmpty && notDomains.isEmpty
    }
}

/// Parses uBlock Origin / EasyList / AdGuard network filter syntax into
/// `UBOFilter` values. Cosmetic filters (`##`) and scriptlet injections are
/// reported via `cosmeticCount` (WebKit content blockers cannot express
/// them) but never block parsing of the rest of the list.
public enum UBOFilterParser {
    public static func parse(_ line: String) -> UBOFilter {
        var rule = line.trimmingCharacters(in: .whitespaces)
        guard !rule.isEmpty else { return .ignore }
        if rule.hasPrefix("!") || rule.hasPrefix("#") || rule.hasPrefix("[") {
            return .ignore
        }
        // Cosmetic filters: `example.com##.ad` or `example.com#@#.ad`.
        if rule.contains("##") || rule.contains("#@#") || rule.contains("#?#") {
            return .ignore
        }

        var isException = false
        if rule.hasPrefix("@@") {
            isException = true
            rule.removeFirst(2)
        }

        // Options after '$'.
        var options = UBOFilterOptions()
        if let dollar = rule.lastIndex(of: "$") {
            let optionText = String(rule[rule.index(after: dollar)...])
            rule = String(rule[..<dollar])
            options = parseOptions(optionText)
        }

        // Strip the trailing anchor '^'.
        var pattern = rule
        if pattern.hasSuffix("^") {
            pattern.removeLast()
        }

        let prefix: UBOFilter
        if pattern.hasPrefix("||") {
            let rest = String(pattern.dropFirst(2))
            if let slash = rest.firstIndex(of: "/") {
                let host = String(rest[..<slash])
                let path = String(rest[rest.index(after: slash)...])
                prefix = .anchoredPath(host: host, path: path, options: options)
            } else {
                prefix = .hostname(host: rest, options: options)
            }
        } else if pattern.hasPrefix("|") {
            // Anchored start without a hostname — treat as substring.
            prefix = .substring(pattern: String(pattern.dropFirst()), options: options)
        } else if pattern.contains("/") && !pattern.hasPrefix("http") {
            prefix = .substring(pattern: pattern, options: options)
        } else {
            prefix = .plain(host: pattern, options: options)
        }

        if isException {
            return .exception(pattern: pattern, options: options)
        }
        return prefix
    }

    /// Parses the `$option1,option2=value` fragment.
    public static func parseOptions(_ text: String) -> UBOFilterOptions {
        var resourceTypes = Set<String>()
        var loadType: String?
        var domains: [String] = []
        var notDomains: [String] = []

        let tokens = text.split(separator: ",")
        for token in tokens {
            let t = String(token)
            switch t {
            case "third-party":
                loadType = "third-party"
            case "first-party":
                loadType = "first-party"
            case "script", "image", "stylesheet", "font", "media", "raw", "document", "xmlhttprequest", "websocket",
                "other":
                resourceTypes.insert(t)
            case "domain":
                // bare $domain (no value) is malformed — ignore
                break
            default:
                if t.hasPrefix("domain=") {
                    let spec = String(t.dropFirst("domain=".count))
                    for part in spec.split(separator: "|") {
                        if part.hasPrefix("~") {
                            notDomains.append(String(part.dropFirst()))
                        } else {
                            domains.append(String(part))
                        }
                    }
                }
            // Unsupported options (removeparam, redirect, csp, …) are
            // dropped silently: the rule still blocks, just without the
            // extra behavior.
            }
        }
        return UBOFilterOptions(
            resourceTypes: resourceTypes, loadType: loadType, domains: domains, notDomains: notDomains)
    }
}
