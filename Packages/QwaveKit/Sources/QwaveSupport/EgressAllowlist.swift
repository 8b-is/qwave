import Foundation

/// The committed allowlist of hosts Qwave's OWN code (Category A in
/// docs/NETWORK.md) is permitted to contact. This is a **reviewed statement of
/// intent, not a runtime gate**: `permits(host:)` has no production call site
/// — every caller is in `EgressGuardTests` — so a running Qwave never consults
/// it, and adding a connection to a host that is not here does NOT fail the
/// test by itself. Nothing enumerates network call sites; a reviewer has to
/// notice the new one and add an assertion (issue #77). Keep the list current
/// anyway: it is what a reviewer checks a diff against, and new egress must be
/// documented in docs/NETWORK.md.
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
        // user-configurable to any HTTPS endpoint). Carries the page text you
        // summarise or ask about; a timeline summary carries titles, times and
        // hosts instead. Stored memory bodies are never attached.
        // See docs/NETWORK.md.
        "api.x.ai",
        // Omnibox autocomplete suggestions (off by default,
        // `networkSuggestionsEnabled`). Carries the text you are typing into
        // the omnibox; transport is cookieless and ephemeral. See
        // docs/NETWORK.md and issue #78.
        "duckduckgo.com",
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
