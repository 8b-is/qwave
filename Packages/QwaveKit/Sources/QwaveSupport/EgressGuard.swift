import Foundation

/// The runtime half of `EgressAllowlist` (issue #77). Until this file,
/// `EgressAllowlist.permits(host:)` had no production call site — the
/// allowlist was a reviewed statement of intent that CI checked against three
/// hand-picked endpoints, not something a running Qwave ever consulted. This
/// `URLProtocol` is the actual runtime gate: installed, it inspects every
/// request's host and refuses anything not on `EgressAllowlist` before it
/// reaches the network.
///
/// Scope, honestly, same caveats the issue raised:
///  - `URLProtocol.registerClass(EgressGuard.self)` (called once at process
///    start, see `main.swift`) reaches exactly one session: `URLSession
///    .shared`, which is documented to consult the shared custom-protocol
///    list. It does **not** reach a session you construct yourself, not even
///    from `URLSessionConfiguration.default` — a constructed session consults
///    only its own `protocolClasses`. Every fixed-host Qwave client on `main`
///    builds its own session, so each must add `EgressGuard.self` explicitly:
///    see `EgressGuard.install(into:)` below and its call sites
///    (`MullvadCertificatePinner.mullvadPinned()`,
///    `SearchSuggestionProvider.swift`, `MemoryProvider.swift`). Pinned by
///    `EgressGuardTests.testConstructedDefaultConfigurationSessionIsNotReachedByRegisterClass`,
///    because reading that sentence as "default-configuration sessions are
///    covered" is what let the markdown regression below through.
///  - It governs Category A only (docs/NETWORK.md) — connections this
///    codebase's own `URLSession` clients initiate. It cannot see Category B
///    (page subresources) or Category C (WebKit's own network process);
///    those never go through `URLSession` at all.
///  - Some Category-A clients are **deliberately** not gated here because
///    their destination is not a fixed set of hosts by design: the favicon
///    loader and remote-markdown fetch are page-driven, and the VPN's
///    in-tunnel quantum handshake target is intentionally excluded from the
///    open-internet allowlist. Gating those here would either break an
///    intentional feature or duplicate an existing guard; see the call sites
///    for the per-client rationale.
///  - Memory Wave's provider **is** gated, as of this change. It used to head
///    the list above, on the argument that a base URL the user can point
///    anywhere cannot be allowlisted — which was true of the committed list
///    and true of nothing else, so the practical effect was that the guard
///    never saw a single provider request. It now installs into the provider's
///    session like any other fixed-host client, and the user-configurable part
///    is carried per request by `markUserConfiguredEndpoint(_:)` +
///    `userConfiguredEndpoint`, which reads the live preference at check time
///    rather than caching a host anywhere. `MemoryWavePolicy` and
///    `EndpointRedirectPolicy` still guard that path for what they always
///    guarded (declared intent, and redirects off the configured origin);
///    this adds the host check they never performed.
///
/// Two of those exclusions hold for **different mechanical reasons**, and
/// conflating them cost a working feature. `FaviconLoader`
/// builds its own session and simply never calls `install(into:)`, so
/// nothing here ever sees it. The remote-markdown fetch does not: it runs on
/// `URLSession.shared` (`BrowserCore/NavigationCoordinator.swift`), the one
/// session `registerClass` above *does* reach. So for four documents' worth of
/// prose claiming it was ungated, it was in fact gated — and navigating to any
/// `.md` URL off the four-host allowlist failed with `BlockedError` instead of
/// rendering. `markPageDriven(_:)` below is the exclusion those documents
/// described, made real and greppable.
public final class EgressGuard: URLProtocol {
    /// Key under which ``markPageDriven(_:)`` stamps its provenance flag. A
    /// `URLProtocol` property rather than a header: it reaches `canInit`
    /// through `URLSession` but never appears on the wire, so marking a
    /// request tells the guard something without telling the destination
    /// anything.
    private static let pageDrivenKey = "is.8b.qwave.EgressGuard.pageDriven"

    /// Marks a request as **page-driven** — its destination host comes from
    /// the page the user navigated to, not from a host Qwave's own source
    /// picked — and so exempts it from `EgressAllowlist`. The allowlist is a
    /// list of hosts *Qwave* chose to contact; it has nothing to say about a
    /// host *you* chose by typing a URL.
    ///
    /// **This is a hole in the guard by construction, so it is worth being
    /// exact about how big.** Any code that calls this bypasses the allowlist,
    /// and nothing mechanically restricts who may call it — a reviewer does,
    /// which is why the marker is a distinct greppable symbol rather than a
    /// side effect of which `URLSessionConfiguration` constant someone happened
    /// to type. What bounds it in practice is that it is per-request, not
    /// per-session: `URLSession.shared` stays gated for everything else, and a
    /// fixed-host client added to that session later is still caught.
    ///
    /// The privacy cost at the sole call site is close to nil, and that is not
    /// a general licence. `NavigationCoordinator.fetchAndPresentMarkdown` runs
    /// from `decidePolicyFor navigationResponse` — WebKit has *already*
    /// connected to that host and received response headers by then (Category
    /// B/C, outside this guard's reach either way). The marked request is a
    /// second fetch of a document the browser just retrieved at the user's
    /// explicit instruction: no new destination, no data the host did not
    /// already receive. A future caller that cannot make that same argument
    /// does not belong here.
    public static func markPageDriven(_ request: URLRequest) -> URLRequest {
        guard let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            return request
        }
        URLProtocol.setProperty(true, forKey: pageDrivenKey, in: mutable)
        return mutable as URLRequest
    }

    /// Whether `request` carries the ``markPageDriven(_:)`` provenance flag.
    static func isPageDriven(_ request: URLRequest) -> Bool {
        URLProtocol.property(forKey: pageDrivenKey, in: request) != nil
    }

    /// Key under which ``markUserConfiguredEndpoint(_:)`` stamps its flag.
    private static let userConfiguredEndpointKey = "is.8b.qwave.EgressGuard.userConfiguredEndpoint"

    /// Where the guard reads the user's currently configured Memory Wave
    /// endpoint. See ``EgressUserConfiguredEndpoint``.
    public static let userConfiguredEndpoint = EgressUserConfiguredEndpoint()

    /// Marks a request as Memory Wave's provider request, making it — and only
    /// it — eligible for the host the user configured in Settings.
    ///
    /// **Unlike ``markPageDriven(_:)`` this grants nothing on its own.** A
    /// marked request still has to be going to the host
    /// ``userConfiguredEndpoint`` reports *at the moment the guard checks it*,
    /// and that is read straight out of the live preference. So marking cannot
    /// name a host, cannot widen the allowlist, and cannot outlive the request
    /// it is stamped on: the two ways a caller could abuse `markPageDriven`
    /// (pick your own destination, or exempt something permanently) are both
    /// unavailable here.
    ///
    /// That is also why the permission is stamped per request rather than kept
    /// in a slot on `EgressAllowlist`. A slot would be process-wide — the host
    /// would be reachable by `URLSession.mullvadPinned()`, the DuckDuckGo
    /// suggestion session, and everything on `URLSession.shared`, none of which
    /// the user consented to when they typed an endpoint for Memory Wave.
    public static func markUserConfiguredEndpoint(_ request: URLRequest) -> URLRequest {
        guard let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            return request
        }
        URLProtocol.setProperty(true, forKey: userConfiguredEndpointKey, in: mutable)
        return mutable as URLRequest
    }

    /// Whether `request` carries the ``markUserConfiguredEndpoint(_:)`` flag.
    static func isUserConfiguredEndpoint(_ request: URLRequest) -> Bool {
        URLProtocol.property(forKey: userConfiguredEndpointKey, in: request) != nil
    }

    /// Failure surfaced to the caller when a request's host is not on
    /// `EgressAllowlist`. Callers see this exactly as any other
    /// `URLSession` transport error (thrown from `session.data(for:)`, etc).
    ///
    /// `URLSession` does not hand this back as the Swift type it was thrown
    /// as: it re-wraps a `URLProtocol` failure into an `NSError` of its own
    /// (carrying `_NSURLErrorRelatedURLSessionTaskErrorKey`), and the original
    /// Swift error box does not survive that. `catch let e as BlockedError`
    /// therefore does **not** match on the far side of a real session. Since
    /// the entire purpose of this type is to cross that boundary, it declares
    /// a stable `CustomNSError` domain/code and carries the host in
    /// `errorUserInfo`, and ``init(recovering:)`` reconstructs it from
    /// whatever `URLSession` delivered. Use that, not a type cast, to tell
    /// "our own policy refused this" apart from "the network failed".
    public struct BlockedError: Error, CustomStringConvertible, Equatable, CustomNSError {
        public let host: String
        public var description: String {
            "egress blocked: \(host) is not on EgressAllowlist"
        }

        public static let errorDomain = "is.8b.qwave.EgressGuard.Blocked"
        /// Key under which ``host`` travels in `errorUserInfo`.
        public static let hostKey = "is.8b.qwave.EgressGuard.host"
        public var errorCode: Int { 1 }
        public var errorUserInfo: [String: Any] {
            [Self.hostKey: host, NSLocalizedDescriptionKey: description]
        }

        public init(host: String) {
            self.host = host
        }

        /// Recovers a `BlockedError` from the error a `URLSession` actually
        /// throws, or returns `nil` if the failure came from anywhere else.
        /// Handles both the direct Swift error (no session in between) and the
        /// `NSError` form, including when `URLSession` nests ours under
        /// `NSUnderlyingErrorKey`.
        public init?(recovering error: any Error) {
            if let blocked = error as? BlockedError {
                self = blocked
                return
            }
            let ns = error as NSError
            if ns.domain == BlockedError.errorDomain,
                let host = ns.userInfo[BlockedError.hostKey] as? String
            {
                self.init(host: host)
                return
            }
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
                let recovered = BlockedError(recovering: underlying)
            {
                self = recovered
                return
            }
            return nil
        }
    }

    /// Diagnostic/test recorder: every blocked host is appended here (thread
    /// safe, may be called from any queue) in addition to the `QwaveLog.egress`
    /// line and the thrown `BlockedError`. Tests use `onBlock.hosts()` to
    /// observe a block without depending on error identity surviving
    /// whatever `URLSession` wraps it in; call `onBlock.reset()` between
    /// cases since this is process-lifetime state.
    public static let onBlock = EgressGuardObserver()

    /// Installs `EgressGuard` as this configuration's first protocol class,
    /// alongside whatever the caller already set. Custom-configuration
    /// sessions (ephemeral, pinned, etc.) never consult a globally registered
    /// `URLProtocol`, so any fixed-host Qwave client that owns its own
    /// configuration must opt in through this call explicitly — global
    /// registration alone does not reach it.
    public static func install(into configuration: URLSessionConfiguration) {
        configuration.protocolClasses = [EgressGuard.self] + (configuration.protocolClasses ?? [])
    }

    public override class func canInit(with request: URLRequest) -> Bool {
        // Page-driven: the host came from the page the user navigated to, not
        // from Qwave's source, so `EgressAllowlist` does not apply. See
        // `markPageDriven(_:)` for the (deliberately narrow) rationale.
        if isPageDriven(request) { return false }
        guard let host = request.url?.host else {
            // No host to check (e.g. a file: URL) — nothing for the
            // allowlist to say; let normal handling proceed.
            return false
        }
        // Permitted: return false so this protocol steps aside and the
        // request proceeds through the normal transport. Only a host that
        // fails the allowlist is intercepted (and then failed) below.
        if EgressAllowlist.permits(host: host) { return false }
        // Memory Wave's own provider request, going to the endpoint the user
        // has configured right now. Both halves are required, and the second
        // is re-read here rather than remembered from when the request was
        // built — see `markUserConfiguredEndpoint(_:)`.
        if isUserConfiguredEndpoint(request), userConfiguredEndpoint.permits(host) { return false }
        return true
    }

    public override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    public override func startLoading() {
        let host = request.url?.host ?? "<unknown host>"
        QwaveLog.egress.error("blocked egress to host not on EgressAllowlist: \(host, privacy: .public)")
        EgressGuard.onBlock.record(host)
        // Deliberately no `assertionFailure` here: this same code path is
        // exercised by tests asserting that a disallowed host IS blocked
        // (rather than crashing the process), and a debug-build trap would
        // turn "the guard works" into "the test runner dies". Failing the
        // request with `BlockedError` is itself loud — it surfaces as a
        // thrown error at every call site — and `QwaveLog.egress` plus
        // `onBlock` give a developer both a Console line and a
        // programmatic hook to notice it during development.
        client?.urlProtocol(self, didFailWithError: BlockedError(host: host))
    }

    public override func stopLoading() {
        // Nothing in flight to cancel — startLoading already failed the
        // request synchronously.
    }
}

/// Where `EgressGuard` reads the HTTPS endpoint the user configured for Memory
/// Wave's provider — a **live** read of the preference, not a copy of it.
///
/// Memory Wave's base URL is user-configurable to any HTTPS endpoint (a real,
/// documented feature: self-hosted Ollama, LM Studio, vLLM, a personal
/// gateway). The committed `EgressAllowlist` can only name the default, so the
/// guard needs some way to know the host the user chose, and the obvious one —
/// a slot somebody writes when they build the provider — is wrong in a way
/// worth spelling out, because this is the second attempt.
///
/// **Settings writes the preference and calls nothing else.** Changing the
/// endpoint, or switching the provider off, goes straight to
/// `MemoryWavePreferences` (`MemoryWavePane.swift`); nothing re-resolves a
/// provider, and if the user has stopped using the feature there may be no
/// next inference at all. A slot written when the provider is built would
/// therefore keep the *previous* host permitted for the rest of the process.
/// Reading the preference at check time removes the staleness entirely: there
/// is no cached copy to go stale, so revocation is not an event anyone has to
/// remember to fire.
///
/// Two more bounds, and they are mechanical rather than conventional:
///  - **Per request.** Only a request stamped by
///    `EgressGuard.markUserConfiguredEndpoint(_:)` is eligible, so the
///    permission applies to Memory Wave's own provider request and to nothing
///    else — not `URLSession.mullvadPinned()`, not the DuckDuckGo suggestion
///    session, not `URLSession.shared`. It is not on `EgressAllowlist` at all;
///    `EgressAllowlist.permits(host:)` remains purely the committed list.
///  - **Exact match**, deliberately unlike `EgressAllowlist/hosts`. That list
///    is reviewed source, so granting a vendor its subdomains is a decision
///    someone made in a diff. This is one host a user typed into Settings, and
///    typing `example.com` is not consent for `telemetry.example.com`.
///
/// `source` is installed once, at the app's composition root
/// (`BrowserEnvironment`), out of the same preferences object the provider's
/// base URL comes from — see `MemoryWavePreferences.egressPermittedHost`. It
/// is a closure so that `QwaveSupport` learns where to look without depending
/// on `MemoryWave`. Uninstalled, this reports `nil` and a user-configured
/// endpoint is refused: the failure mode is closed.
///
/// Thread-safe by the same `NSLock` pattern as `EgressGuardObserver`: the guard
/// reads it from `URLProtocol.canInit` on whatever queue `URLSession` runs,
/// while the source is installed on the main actor. The closure itself is
/// called outside the lock (it reads `UserDefaults`, and holding a lock across
/// a caller's code invites a deadlock).
public final class EgressUserConfiguredEndpoint: @unchecked Sendable {
    private let lock = NSLock()
    private var source: (() -> String?)?

    /// Installs the live source of the configured host. Pass `nil` to remove
    /// it (tests do; the app installs one and leaves it).
    public func use(_ source: (() -> String?)?) {
        lock.withLock { self.source = source }
    }

    /// The host the user has configured **right now**, normalized, or `nil`
    /// when no remote endpoint is configured (or no source is installed).
    public func current() -> String? {
        let source = lock.withLock { self.source }
        guard let host = source?()?.lowercased().trimmingCharacters(in: .whitespaces),
            !host.isEmpty
        else { return nil }
        return host
    }

    /// Exact match only — a subdomain of the configured host is not permitted.
    func permits(_ candidate: String) -> Bool {
        current() == candidate.lowercased()
    }
}

/// Thread-safe recorder used by `EgressGuard.onBlock` so tests can assert a
/// block happened without racing the protocol's background queue.
public final class EgressGuardObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var blockedHosts: [String] = []

    public func reset() {
        lock.withLock { blockedHosts = [] }
    }

    func record(_ host: String) {
        lock.withLock { blockedHosts.append(host) }
    }

    public func hosts() -> [String] {
        lock.withLock { blockedHosts }
    }
}
