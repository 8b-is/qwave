import Foundation

/// A WebExtensions standard match pattern parser and matcher.
///
/// Matches patterns following Chrome/Firefox extension specifications:
/// - `<all_urls>`: matches all supported schemes (`http`, `https`, `ws`, `wss`, `file`, `ftp`).
/// - `<scheme>://<host><path>`:
///   - `*://`: matches `http://` and `https://`
///   - `*.example.com`: matches `example.com` and all subdomains (e.g. `foo.example.com`).
///   - `/path/*`: wildcard matching across path components.
public struct URLMatchPattern: Sendable, Equatable, Hashable {
    public let rawPattern: String
    public let isAllURLs: Bool
    public let schemePattern: String?
    public let hostPattern: String?
    public let pathPattern: String?

    private let hostRegex: NSRegularExpression?
    private let pathRegex: NSRegularExpression?

    public init?(_ pattern: String) {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.rawPattern = trimmed

        if trimmed == "<all_urls>" {
            self.isAllURLs = true
            self.schemePattern = nil
            self.hostPattern = nil
            self.pathPattern = nil
            self.hostRegex = nil
            self.pathRegex = nil
            return
        }

        self.isAllURLs = false

        guard let schemeSeparator = trimmed.range(of: "://") else {
            return nil
        }

        let scheme = String(trimmed[..<schemeSeparator.lowerBound])
        let afterScheme = String(trimmed[schemeSeparator.upperBound...])

        // Scheme validation
        let validSchemes = ["*", "http", "https", "file", "ftp", "ws", "wss"]
        guard validSchemes.contains(scheme) else {
            return nil
        }
        self.schemePattern = scheme

        // For file scheme, host is empty or *
        if scheme == "file" {
            self.hostPattern = ""
            self.hostRegex = nil
            let path = afterScheme.hasPrefix("/") ? afterScheme : "/" + afterScheme
            self.pathPattern = path
            self.pathRegex = Self.compileWildcardRegex(pattern: path)
            return
        }

        guard let firstSlash = afterScheme.firstIndex(of: "/") else {
            return nil
        }

        let host = String(afterScheme[..<firstSlash])
        let path = String(afterScheme[firstSlash...])

        guard !host.isEmpty, !path.isEmpty else {
            return nil
        }

        self.hostPattern = host
        self.pathPattern = path

        self.hostRegex = Self.compileHostRegex(pattern: host)
        self.pathRegex = Self.compileWildcardRegex(pattern: path)
    }

    /// Evaluates whether the given URL matches this pattern.
    public func matches(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }

        if isAllURLs {
            return ["http", "https", "ws", "wss", "file", "ftp"].contains(scheme)
        }

        // 1. Check scheme
        if let schemePattern {
            if schemePattern == "*" {
                if scheme != "http" && scheme != "https" { return false }
            } else if schemePattern.lowercased() != scheme {
                return false
            }
        }

        // 2. Check host
        if let hostRegex {
            guard let host = url.host?.lowercased() else { return false }
            let range = NSRange(location: 0, length: (host as NSString).length)
            if hostRegex.firstMatch(in: host, options: [], range: range) == nil {
                return false
            }
        }

        // 3. Check path
        if let pathRegex {
            let path = url.path.isEmpty ? "/" : url.path
            let range = NSRange(location: 0, length: (path as NSString).length)
            if pathRegex.firstMatch(in: path, options: [], range: range) == nil {
                return false
            }
        }

        return true
    }

    /// Convenience for matching a string representation of a URL.
    public func matches(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        return matches(url)
    }

    // MARK: - Regex compilation helpers

    private static func compileHostRegex(pattern: String) -> NSRegularExpression? {
        let lower = pattern.lowercased()
        if lower == "*" {
            return try? NSRegularExpression(pattern: "^.+$")
        }
        if lower.hasPrefix("*.") {
            let domain = String(lower.dropFirst(2))
            let escapedDomain = NSRegularExpression.escapedPattern(for: domain)
            // Matches 'domain' exactly OR '*.domain'
            let patternString = "^(?:.+\\.)?" + escapedDomain + "$"
            return try? NSRegularExpression(pattern: patternString)
        }
        let escaped = NSRegularExpression.escapedPattern(for: lower)
        return try? NSRegularExpression(pattern: "^\(escaped)$")
    }

    private static func compileWildcardRegex(pattern: String) -> NSRegularExpression? {
        var regexStr = "^"
        let parts = pattern.components(separatedBy: "*")
        for (index, part) in parts.enumerated() {
            if !part.isEmpty {
                regexStr += NSRegularExpression.escapedPattern(for: part)
            }
            if index < parts.count - 1 {
                regexStr += ".*"
            }
        }
        regexStr += "$"
        return try? NSRegularExpression(pattern: regexStr)
    }
}
