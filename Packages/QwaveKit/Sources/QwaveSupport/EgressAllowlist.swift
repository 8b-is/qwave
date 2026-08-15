import Foundation

/// The committed allowlist of hosts Qwave's OWN code (Category A in
/// docs/NETWORK.md) is permitted to contact.
///
/// `permits(host:)` now has a real runtime call site: `EgressGuard`
/// (`QwaveSupport/EgressGuard.swift`) is a `URLProtocol` that consults this
/// allowlist and fails any request to a host not listed here, and it is
/// wired into every fixed-host Qwave network client (`MullvadAPIClient` via
/// `URLSession.mullvadPinned()`, the DuckDuckGo suggestion provider, and —
/// through `URLProtocol.registerClass` at process start — any default- or
/// shared-configuration session). See #77.
///
/// It still is **not** a mechanical guarantee over the whole codebase: it
/// governs Category A only, a custom-configuration session that skips
/// `EgressGuard.install(into:)` is not caught, and some Category-A clients
/// (Memory Wave's user-configurable endpoint, the favicon loader, the
/// remote-markdown fetch, the VPN's in-tunnel quantum handshake) are
/// deliberately excluded because their destination is not a fixed host by
/// design — see `EgressGuard`'s doc comment for the per-client rationale.
/// Nothing enumerates network call sites either, so a *new* fixed-host
/// client still has to be wired up (and documented in docs/NETWORK.md) by
/// whoever adds it. Keep the list current: it is both what `EgressGuard`
/// checks against at runtime and what a reviewer checks a diff against.
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
