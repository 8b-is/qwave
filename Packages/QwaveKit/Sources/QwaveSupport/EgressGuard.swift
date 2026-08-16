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
///    is carried by `EgressAllowlist.userConfiguredHost`: one slot, exact
///    match, set only from `WaveDirector.resolveProvider()` out of the same
///    preference the base URL comes from. `MemoryWavePolicy` and
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
        return !EgressAllowlist.permits(host: host)
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
