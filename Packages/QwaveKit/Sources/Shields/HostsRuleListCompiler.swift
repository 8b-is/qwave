import Foundation

/// Converts a hosts-format malicious-host blocklist into `WKContentRuleList`
/// JSON (WebKit's content-blocker format), so a known-malicious host is
/// blocked entirely on-device.
///
/// Zero egress: this compiler is pure and local. No host or URL is ever sent
/// to any network service — matching happens 100% inside WebKit's compiled
/// rule list. This is the Safe Browsing counterpart to `UBORuleListCompiler`
/// (which compiles ad/tracker filter lists); it emits the same WebKit-accepted
/// anchored-host url-filter shape (see `hostURLFilter`).
///
/// Accepted line formats (one host per line):
///   - `0.0.0.0 evil.example` / `127.0.0.1 evil.example` (classic hosts file)
///   - `evil.example` (bare host)
///   - `# comment` lines and blank lines are ignored; a trailing `# ...` on a
///     rule line is stripped.
public enum HostsRuleListCompiler {
    /// Loopback aliases that classic hosts files pair with the sink IP; never
    /// emitted as block rules even if present.
    private static let ignored: Set<String> = [
        "localhost", "localhost.localdomain", "local", "broadcasthost", "ip6-localhost", "ip6-loopback",
    ]

    /// The bundled malicious-host source list (Resources/malicious-hosts.txt),
    /// read from the Shields module bundle. `malicious-hosts-compiled.json` is
    /// this file's compilation (see `compileJSON`).
    public static func bundledSource() throws -> String {
        guard let url = Bundle.module.url(forResource: "malicious-hosts", withExtension: "txt") else {
            throw RuleListError.missingResource("malicious-hosts.txt")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Parses a hosts-format document into a sorted, de-duplicated list of
    /// lowercased hostnames.
    public static func hosts(from text: String) -> [String] {
        var seen: Set<String> = []
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine
            if let hash = line.firstIndex(of: "#") {
                line = String(line[..<hash])
            }
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let host = hostToken(from: tokens) else { continue }
            let lower = host.lowercased()
            guard !ignored.contains(lower), lower.contains(".") else { continue }
            seen.insert(lower)
        }
        return seen.sorted()
    }

    /// Picks the hostname token from a hosts-file line's tokens: the second
    /// token when a sink IP prefixes the line, otherwise the sole token.
    private static func hostToken(from tokens: [String]) -> String? {
        switch tokens.count {
        case 0:
            return nil
        case 1:
            return tokens[0]
        default:
            // `<ip> <host> [aliases…]` — take the first host, ignore aliases.
            return tokens[1]
        }
    }

    /// URL-filter matching `host` and all its subdomains on any scheme. Uses
    /// the exact anchored-host shape WebKit's content-blocker regex engine
    /// accepts (no disjunctions, no `$` — those are rejected as "unsupported"),
    /// the same form AdGuard's converter emits for the shipped EasyList.
    static func hostURLFilter(_ host: String) -> String {
        "^[^:]+://+([^:/]+\\.)?\(UBORuleListCompiler.escapeHost(host))[/:]"
    }

    /// Compiles the hosts document into content-blocker JSON: one `block`
    /// rule per host, matching the host and all its subdomains on any scheme.
    /// Output is deterministic (hosts sorted, keys sorted) so the bundled
    /// resource and this compiler stay verifiably in sync.
    public static func compileJSON(from text: String) -> String {
        let rules: [[String: Any]] = hosts(from: text).map { host in
            [
                "trigger": ["url-filter": hostURLFilter(host)],
                "action": ["type": "block"],
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys]) else {
            return "[]"
        }
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}
