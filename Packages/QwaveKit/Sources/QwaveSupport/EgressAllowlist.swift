import Foundation

/// The committed allowlist of hosts Qwave's OWN code (Category A in
/// docs/NETWORK.md) is permitted to contact. This is the single source of
/// truth the egress regression test enforces: if a change adds a connection
/// to a host that is not here, the test fails and the reviewer must either
/// add the host deliberately (and document it in docs/NETWORK.md) or remove
/// the egress.
///
/// Scope, honestly: this governs **Category A** only — connections this
/// codebase initiates. It does NOT cover Category B (subresources of a page
/// you navigated to — those are the open web, governed by Shields, not an
/// allowlist) or Category C (WebKit's own service traffic, e.g. the
/// fraudulent-website warning — those originate inside WebKit's network
/// process, which this cannot see). See docs/NETWORK.md.
public enum EgressAllowlist {
    /// Permitted Category-A hosts, each with why it exists. Favicon and
    /// remote-markdown fetches are deliberately absent: their host is
    /// whatever page you navigated to, so they are page-driven (Category B
    /// in spirit) and cannot be allowlisted to a fixed set.
    public static let hosts: Set<String> = [
        // Auto-update feed (Sparkle). User-consented; see docs/NETWORK.md.
        "github.com",
        // Mullvad VPN control API. Only when the VPN is used.
        "api.mullvad.net",
        // Memory Wave remote AI provider, default endpoint (off by default,
        // user-configurable to any HTTPS endpoint). Titles/times only.
        "api.x.ai",
    ]

    /// True when `host` is a permitted Category-A destination — exact match
    /// or a subdomain of an allowlisted host (e.g. `objects.githubusercontent
    /// .com` is not `github.com`, but `codeload.github.com` is).
    public static func permits(host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        if hosts.contains(host) { return true }
        return hosts.contains { host.hasSuffix(".\($0)") }
    }
}
