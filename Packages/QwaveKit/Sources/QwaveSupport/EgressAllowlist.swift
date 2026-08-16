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
/// governs Category A only, a constructed session that skips
/// `EgressGuard.install(into:)` is not caught, and some Category-A clients
/// (the favicon loader, the remote-markdown fetch, the VPN's in-tunnel
/// quantum handshake) are deliberately excluded because their destination is
/// not a fixed host by design — see `EgressGuard`'s doc comment for the
/// per-client rationale.
/// Those exclusions are not all the same mechanism: most simply never install
/// the guard, but the remote-markdown fetch runs on `URLSession.shared` — the
/// one session global registration does reach — and is excluded only because
/// it marks its request with `EgressGuard.markPageDriven(_:)`.
/// Nothing enumerates network call sites either, so a *new* fixed-host
/// client still has to be wired up (and documented in docs/NETWORK.md) by
/// whoever adds it. Keep the list current: it is both what `EgressGuard`
/// checks against at runtime and what a reviewer checks a diff against.
///
/// Memory Wave's provider used to be on that exclusion list. It no longer is:
/// its session installs the guard like any other fixed-host client, and the
/// one thing that makes it different — a base URL the user may point anywhere
/// — is handled by ``userConfiguredHost`` below rather than by opting out.
public enum EgressAllowlist {
    /// Permitted Category-A hosts, each with why it exists. Favicon and
    /// remote-markdown fetches are deliberately absent: their host is
    /// whatever page you navigated to, so they are page-driven (Category B
    /// in spirit) and cannot be allowlisted to a fixed set. Absence from this
    /// list is not what exempts them — being absent is exactly what
    /// `EgressGuard` blocks on — so do not read this comment as the
    /// exemption; the mechanism is in `EgressGuard`.
    public static let hosts: Set<String> = [
        // Auto-update feed (Sparkle). User-consented; see docs/NETWORK.md.
        "github.com",
        // Mullvad VPN control API. Only when the VPN is used.
        "api.mullvad.net",
        // Memory Wave remote AI provider, default endpoint (off by default,
        // user-configurable to any HTTPS endpoint — a host you configure
        // instead is permitted through `userConfiguredHost`, not through this
        // list). Carries the page text you summarise or ask about; a timeline
        // summary carries titles, times and hosts instead. Stored memory
        // bodies are never attached. See docs/NETWORK.md.
        "api.x.ai",
        // Omnibox autocomplete suggestions (off by default,
        // `networkSuggestionsEnabled`). Carries the text you are typing into
        // the omnibox; transport is cookieless and ephemeral. See
        // docs/NETWORK.md and issue #78.
        "duckduckgo.com",
    ]

    /// The single host the **user** pointed Memory Wave's provider at, when
    /// that is not the committed default. See ``EgressUserConfiguredHost`` for
    /// why it is one slot, exact-match, and set from exactly one place.
    public static let userConfiguredHost = EgressUserConfiguredHost()

    /// True when `host` is a permitted Category-A destination: exact match or
    /// a subdomain of a committed ``hosts`` entry (e.g. `objects
    /// .githubusercontent.com` is not `github.com`, but `codeload.github.com`
    /// is), **or** an exact match on ``userConfiguredHost``.
    ///
    /// The two halves match differently on purpose. ``hosts`` is reviewed
    /// source, so granting a vendor its subdomains is a decision someone made
    /// in a diff. ``userConfiguredHost`` is one host a user typed into
    /// Settings, and typing `example.com` is not consent for
    /// `telemetry.example.com`.
    public static func permits(host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        if hosts.contains(host) { return true }
        if hosts.contains(where: { host.hasSuffix(".\($0)") }) { return true }
        return userConfiguredHost.matches(host)
    }
}

/// The one-slot exception to the committed allowlist: the host of the HTTPS
/// endpoint the user configured for Memory Wave's provider.
///
/// Memory Wave's base URL is user-configurable to any HTTPS endpoint — a real,
/// documented feature (self-hosted Ollama, LM Studio, vLLM, a personal
/// gateway). Gating that session against the committed list alone would keep
/// the default `api.x.ai` working and break every endpoint anyone actually
/// typed, so the guard needs to know the one host the user chose.
///
/// Three properties keep this from being a hole:
///  - **One slot.** Setting replaces; there is no growing set of hosts the
///    guard has accumulated over a session. Point the provider somewhere else
///    and the previous host is revoked in the same call. `nil` clears it.
///  - **Exact match only**, deliberately unlike ``EgressAllowlist/hosts``.
///  - **One writer.** `WaveDirector.resolveProvider()` is the only place that
///    sets it, from the same preference the provider's base URL comes from, so
///    the slot cannot drift from what the user configured. Scattering setters
///    is how it would become a set of stale hosts.
///
/// Thread-safe by the same `NSLock` pattern as `EgressGuardObserver`: the
/// guard reads it from `URLProtocol.canInit` on whatever queue `URLSession`
/// runs, while the writer is on the main actor.
public final class EgressUserConfiguredHost: @unchecked Sendable {
    private let lock = NSLock()
    private var host: String?

    /// Replaces the slot. Pass `nil` (or a host-less URL) to clear it.
    public func set(_ newValue: String?) {
        let normalized = newValue?.lowercased().trimmingCharacters(in: .whitespaces)
        lock.withLock { host = (normalized?.isEmpty ?? true) ? nil : normalized }
    }

    /// The currently permitted user host, or `nil` when none is set.
    public func current() -> String? {
        lock.withLock { host }
    }

    /// Exact match only — a subdomain of the configured host is not permitted.
    func matches(_ candidate: String) -> Bool {
        lock.withLock { host == candidate }
    }
}
