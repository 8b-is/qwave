import WebKit
import XCTest

@testable import BrowserCore
@testable import MemoryWave
@testable import QwaveSupport
@testable import Shields
@testable import VPNKit

/// The egress regression gate (docs/NETWORK.md, "prove what it sends").
///
/// Historically this suite only checked the `EgressAllowlist` *data* — three
/// known Category-A endpoints pinned by hand-written assertions, and a
/// rejection test for unknown hosts — without anything in production ever
/// consulting the allowlist at runtime (issue #77). `EgressGuard`
/// (`QwaveSupport/EgressGuard.swift`) closes that gap: it is a `URLProtocol`
/// wired into every fixed-host Qwave network client, and the tests below
/// exercise it end-to-end through real `URLSession` machinery (a disallowed
/// host is actually blocked by the installed protocol, not just rejected by
/// calling `EgressAllowlist.permits(host:)` directly) rather than only
/// asserting over the allowlist's data.
///
/// Five groups of checks, still narrower than they first look:
///  1. Three known Category-A endpoints are pinned to the committed
///     `EgressAllowlist` by the hand-written assertions below. Nothing
///     enumerates network call sites, so adding a new default endpoint
///     WITHOUT allowlisting it and wiring `EgressGuard` into its session does
///     not fail this test — a reviewer still has to notice, as was missed for
///     `duckduckgo.com` until issue #78. For that host no assertion here
///     could have reached the call site even in principle: this target did
///     not depend on `BrowserCore` at all until then.
///  2. `EgressGuard` runtime tests: a disallowed host is blocked when routed
///     through a session that installed the guard, an allowlisted host is
///     not, and the three production call sites (`URLSession.mullvadPinned()`,
///     `DuckDuckGoSuggestionProvider`'s default session,
///     `OpenAICompatibleProvider`'s default session) are asserted to
///     have installed it. The provider's is the newest of the three and the
///     one that was missing: its session is ephemeral and never installed the
///     guard, so `api.x.ai` sat on the allowlist while not one provider
///     request was ever checked against it.
///  3. The always-on launch path (shields preparation) makes no URLSession
///     request — the launch-time blocklist fetch was removed. Scope: the
///     recorder below is installed with `URLProtocol.registerClass`, which
///     reaches `URLSession.shared` and nothing else, and this test drives a
///     `ShieldsDirector` it constructs itself rather than the app's launch
///     sequence.
///  4. The page-driven exemption: navigating to a `.md` document on a
///     non-allowlisted host must still render, the exemption must not widen
///     to the host or the session, and `registerClass`'s actual reach is
///     pinned so the prose about it cannot drift again.
///  5. The user-configured host slot, which is what lets the provider be
///     gated without breaking the endpoint a user typed: the committed
///     default endpoint still reaches the transport, a host set in the slot is
///     reached, a *subdomain* of that host is not, and replacing or clearing
///     the slot revokes the previous host.
///
/// Honest scope: `EgressGuard` catches Category A (Qwave's own egress) for
/// any client that either uses `URLSession.shared` (covered by the
/// process-wide `URLProtocol.registerClass` in `main.swift`) or installs it
/// into its own configuration explicitly (`EgressGuard.install(into:)`).
/// It does not cover a fixed-host client that skips that call, a
/// deliberately open-ended client (`FaviconLoader`, remote-markdown fetch —
/// see `EgressGuard`'s doc comment), Category B (page subresources), or
/// Category C (WebKit's own network process, e.g. the fraudulent-website
/// warning). See docs/NETWORK.md.
final class EgressGuardTests: XCTestCase {

    /// `EgressAllowlist.userConfiguredHost` is process-lifetime state, like
    /// `EgressGuard.onBlock`. Clear it so one case cannot permit a host for
    /// the next one.
    override func tearDown() {
        EgressAllowlist.userConfiguredHost.set(nil)
        super.tearDown()
    }

    // MARK: - Allowlist ↔ endpoint consistency

    func testMullvadDefaultEndpointIsAllowlisted() {
        let client = MullvadAPIClient()
        XCTAssertTrue(
            EgressAllowlist.permits(host: client.baseURL.host),
            "Mullvad API host \(client.baseURL.host ?? "nil") must be on the egress allowlist"
        )
    }

    func testMemoryProviderDefaultEndpointIsAllowlisted() {
        let host = MemoryWavePreferences.defaultRemoteBaseURL.host
        XCTAssertTrue(
            EgressAllowlist.permits(host: host),
            "Memory Wave default AI host \(host ?? "nil") must be on the egress allowlist"
        )
    }

    func testSparkleFeedHostIsAllowlisted() {
        // SUFeedURL lives in project.yml (releases/latest/download/appcast.xml
        // on github.com); assert the host it resolves to is permitted.
        XCTAssertTrue(EgressAllowlist.permits(host: "github.com"))
        XCTAssertTrue(EgressAllowlist.permits(host: "objects.githubusercontent.com") == false)
    }

    /// Omnibox network suggestions (off by default) hit `duckduckgo.com/ac/`
    /// — see `DuckDuckGoSuggestionProvider` in
    /// `BrowserCore/SearchSuggestionProvider.swift`. Issue #78: this host was
    /// hardcoded in a call site but absent from the allowlist and
    /// docs/NETWORK.md's Category A table.
    func testDuckDuckGoSuggestionEndpointIsAllowlisted() {
        let url = URL(string: "https://duckduckgo.com/ac/?q=swift&type=list")
        XCTAssertTrue(
            EgressAllowlist.permits(host: url?.host),
            "DuckDuckGo suggestion host \(url?.host ?? "nil") must be on the egress allowlist"
        )
    }

    /// The post-quantum key exchange targets the relay's in-tunnel gateway
    /// (10.64.0.1), reachable only INSIDE the VPN — never open-internet
    /// egress. It is deliberately NOT on the allowlist, and the allowlist
    /// must not accidentally permit it.
    func testInTunnelQuantumEndpointIsNotOpenEgress() {
        let transport = MullvadEphemeralPeerTransport()
        XCTAssertFalse(
            EgressAllowlist.permits(host: transport.endpoint.host),
            "the in-tunnel PQ endpoint must not be treated as an allowlisted open-internet host"
        )
    }

    /// The omnibox suggestion endpoint is Category A: its host is fixed in
    /// Qwave's source, not derived from a page you navigated to. It stayed
    /// invisible to this suite for an entire release because the test target
    /// did not depend on `BrowserCore` at all, so no assertion here could
    /// reach the provider (issue #78).
    ///
    /// The host is read out of the request the provider actually builds — a
    /// capturing `URLProtocol` on an injected session — rather than restated
    /// as a literal, so this asserts against the real call site instead of
    /// against itself.
    func testSuggestionEndpointHostIsAllowlisted() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SuggestionCapture.self]
        let provider = DuckDuckGoSuggestionProvider(session: URLSession(configuration: config))

        _ = try await provider.fetchSuggestions(for: "qwave")

        let host = SuggestionCapture.captured.url()?.host
        XCTAssertNotNil(host, "the suggestion provider must have issued a request to capture")
        XCTAssertTrue(
            EgressAllowlist.permits(host: host),
            "omnibox suggestion host \(host ?? "nil") must be on the egress allowlist"
        )
    }

    func testAllowlistRejectsUnknownHosts() {
        XCTAssertFalse(EgressAllowlist.permits(host: "example.com"))
        XCTAssertFalse(EgressAllowlist.permits(host: "evil.tracker.net"))
        XCTAssertFalse(EgressAllowlist.permits(host: nil))
        XCTAssertFalse(EgressAllowlist.permits(host: ""))
        // subdomain match works; sibling-domain confusion does not
        XCTAssertTrue(EgressAllowlist.permits(host: "codeload.github.com"))
        XCTAssertFalse(EgressAllowlist.permits(host: "github.com.evil.net"))
    }

    // MARK: - EgressGuard: runtime enforcement (issue #77)

    /// A trivial stub protocol standing in for "the request actually reached
    /// the network transport". Registered after `EgressGuard` in
    /// `protocolClasses`, so it only ever sees a request `EgressGuard` chose
    /// not to intercept (i.e. an allowlisted host) — it is proof, not an
    /// assumption, that a blocked request never gets this far.
    final class StubTransport: URLProtocol {
        nonisolated(unsafe) static var receivedHosts: [String] = []
        private static let lock = NSLock()

        static func reset() {
            lock.withLock { receivedHosts = [] }
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            if let host = request.url?.host {
                Self.lock.withLock { Self.receivedHosts.append(host) }
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func makeGuardedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EgressGuard.self, StubTransport.self]
        return URLSession(configuration: configuration)
    }

    /// The core claim of #77: a disallowed host is blocked by `EgressGuard`
    /// through real `URLSession` request handling — not merely rejected by a
    /// direct call to `EgressAllowlist.permits(host:)`.
    func testEgressGuardBlocksDisallowedHostAtRuntime() async {
        EgressGuard.onBlock.reset()
        StubTransport.reset()
        let session = makeGuardedSession()

        do {
            _ = try await session.data(from: URL(string: "https://evil.tracker.net/probe")!)
            XCTFail("request to a non-allowlisted host must not succeed")
        } catch {
            // Recovered rather than type-cast: URLSession re-wraps a
            // URLProtocol failure in an NSError of its own, so `as?
            // BlockedError` does not match here even though the guard is
            // what failed the request. This asserts the thing that actually
            // matters to a caller — that they can still tell OUR refusal
            // apart from a network failure, and learn which host.
            let blocked = EgressGuard.BlockedError(recovering: error)
            XCTAssertNotNil(blocked, "caller must be able to identify an egress block, got \(error)")
            XCTAssertEqual(blocked?.host, "evil.tracker.net")
        }

        XCTAssertEqual(EgressGuard.onBlock.hosts(), ["evil.tracker.net"])
        XCTAssertTrue(
            StubTransport.receivedHosts.isEmpty,
            "a blocked request must never reach the network transport"
        )
    }

    /// The companion claim: wiring the guard into a session must not break
    /// an allowlisted host — it has to step aside and let the real request
    /// proceed.
    func testEgressGuardAllowsAllowlistedHostAtRuntime() async throws {
        EgressGuard.onBlock.reset()
        StubTransport.reset()
        let session = makeGuardedSession()

        let (_, response) = try await session.data(from: URL(string: "https://github.com/probe")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        XCTAssertEqual(StubTransport.receivedHosts, ["github.com"])
        XCTAssertTrue(EgressGuard.onBlock.hosts().isEmpty)
    }

    /// Production call site 1: the Mullvad control-API transport pins TLS
    /// AND must install `EgressGuard`, since it is a custom-configuration
    /// session the process-wide registration in `main.swift` never reaches.
    func testMullvadPinnedSessionInstallsEgressGuard() {
        let session = URLSession.mullvadPinned()
        XCTAssertTrue(
            session.configuration.protocolClasses?.contains(where: { $0 == EgressGuard.self }) ?? false,
            "URLSession.mullvadPinned() must install EgressGuard so api.mullvad.net traffic is runtime-checked"
        )
    }

    /// Production call site 2: the DuckDuckGo suggestion provider's default
    /// session is also a custom configuration and must install the guard.
    func testDuckDuckGoSuggestionProviderInstallsEgressGuard() {
        let provider = DuckDuckGoSuggestionProvider()
        XCTAssertTrue(
            provider.session.configuration.protocolClasses?.contains(where: { $0 == EgressGuard.self }) ?? false,
            "DuckDuckGoSuggestionProvider's default session must install EgressGuard"
        )
    }

    /// Production call site 3: Memory Wave's remote provider. Its default
    /// session is built from `URLSessionConfiguration.ephemeral`, so the
    /// process-wide `registerClass` in `main.swift` never reaches it either.
    func testMemoryProviderDefaultSessionInstallsEgressGuard() {
        let provider = OpenAICompatibleProvider(
            baseURL: MemoryWavePreferences.defaultRemoteBaseURL,
            model: "grok-4.6",
            apiKey: "test-key"
        )
        XCTAssertTrue(
            provider.session.configuration.protocolClasses?.contains(where: { $0 == EgressGuard.self }) ?? false,
            "the Memory Wave provider's default session must install EgressGuard"
        )
    }

    /// `.invalid` is reserved by RFC 6761 and never resolves, so this makes no
    /// real connection either way — which is exactly what makes it a clean
    /// red/green: ungated, the request dies at DNS and `BlockedError` does not
    /// recover; gated, the guard refuses it before the transport is reached.
    func testMemoryProviderSessionRefusesAHostNobodyConfigured() async {
        EgressGuard.onBlock.reset()
        let provider = OpenAICompatibleProvider(
            baseURL: URL(string: "https://qwave-provider-probe.invalid/v1")!,
            model: "grok-4.6",
            apiKey: "test-key",
            timeout: 5
        )
        do {
            _ = try await provider.complete(system: "system", user: "user")
            XCTFail("a request to a host that is neither allowlisted nor user-set must not succeed")
        } catch {
            let blocked = EgressGuard.BlockedError(recovering: error)
            XCTAssertNotNil(blocked, "the provider's session must be gated by EgressGuard, got \(error)")
            XCTAssertEqual(blocked?.host, "qwave-provider-probe.invalid")
        }
    }

    // MARK: - The user-configured host slot

    /// A session gated the way `OpenAICompatibleProvider.defaultSession` is
    /// gated — through `EgressGuard.install(into:)`, not by assembling
    /// `protocolClasses` by hand — with a stub standing in for the transport,
    /// so a permitted request is observable without leaving the machine.
    private func makeProviderStyleSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubTransport.self]
        EgressGuard.install(into: configuration)
        return URLSession(configuration: configuration)
    }

    /// Issues one real provider request at `baseURL` and reports the guard's
    /// refusal, or `nil` when the request got past it. `nil` also covers the
    /// stub's malformed-completion error, which is why every case below also
    /// asserts over `StubTransport.receivedHosts`.
    private func askProvider(at baseURL: String, on session: URLSession) async -> EgressGuard.BlockedError? {
        let provider = OpenAICompatibleProvider(
            baseURL: URL(string: baseURL)!,
            model: "grok-4.6",
            apiKey: "test-key",
            timeout: 5,
            session: session
        )
        do {
            _ = try await provider.complete(system: "system", user: "user")
            return nil
        } catch {
            return EgressGuard.BlockedError(recovering: error)
        }
    }

    /// The regression the naive fix would have shipped, in reverse: gating the
    /// provider must not break the endpoint that ships in the box.
    func testProviderDefaultEndpointStillReachesTheTransport() async {
        EgressGuard.onBlock.reset()
        StubTransport.reset()
        XCTAssertNil(EgressAllowlist.userConfiguredHost.current(), "the default endpoint needs no user slot")

        let blocked = await askProvider(
            at: MemoryWavePreferences.defaultRemoteBaseURL.absoluteString, on: makeProviderStyleSession())

        XCTAssertNil(blocked, "the committed default endpoint must not be refused")
        XCTAssertEqual(StubTransport.receivedHosts, ["api.x.ai"])
        XCTAssertTrue(EgressGuard.onBlock.hosts().isEmpty)
    }

    /// The feature the slot exists for: an endpoint the user typed is reached.
    /// And the bound on it — a *subdomain* of that host is still refused,
    /// because the static list's subdomain matching is a decision made in a
    /// reviewed diff and this one is a host somebody typed into Settings.
    func testUserConfiguredHostPermitsExactlyThatHostAndNotItsSubdomains() async {
        EgressGuard.onBlock.reset()
        StubTransport.reset()
        let session = makeProviderStyleSession()
        EgressAllowlist.userConfiguredHost.set("self-hosted.example")

        let allowed = await askProvider(at: "https://self-hosted.example/v1", on: session)
        XCTAssertNil(allowed, "the configured endpoint must be reachable")
        XCTAssertEqual(StubTransport.receivedHosts, ["self-hosted.example"])

        let subdomain = await askProvider(at: "https://telemetry.self-hosted.example/v1", on: session)
        XCTAssertEqual(
            subdomain?.host, "telemetry.self-hosted.example",
            "configuring a host must not silently grant its subdomains")
        XCTAssertEqual(
            StubTransport.receivedHosts, ["self-hosted.example"],
            "exactly the configured host may reach the transport")
    }

    /// The slot holds one host, and both ways of leaving a host behind revoke
    /// it: clearing (the user turned the provider off) and replacing (the user
    /// pointed it somewhere else). Without this the guard would accumulate
    /// every host configured during a session.
    func testUserConfiguredHostIsRevokedByClearingAndByReplacing() async {
        EgressGuard.onBlock.reset()
        StubTransport.reset()
        let session = makeProviderStyleSession()

        EgressAllowlist.userConfiguredHost.set("first.example")
        EgressAllowlist.userConfiguredHost.set("second.example")
        XCTAssertEqual(EgressAllowlist.userConfiguredHost.current(), "second.example")

        let replaced = await askProvider(at: "https://first.example/v1", on: session)
        XCTAssertEqual(replaced?.host, "first.example", "replacing must revoke the previous host")
        let current = await askProvider(at: "https://second.example/v1", on: session)
        XCTAssertNil(current, "the host now configured must be reachable")

        EgressAllowlist.userConfiguredHost.set(nil)
        let cleared = await askProvider(at: "https://second.example/v1", on: session)
        XCTAssertEqual(cleared?.host, "second.example", "clearing must revoke the host")

        XCTAssertEqual(StubTransport.receivedHosts, ["second.example"])
        XCTAssertEqual(EgressGuard.onBlock.hosts(), ["first.example", "second.example"])
    }

    /// The slot's semantics without a session in the way.
    func testUserConfiguredHostMatchingIsExactAndCaseInsensitive() {
        XCTAssertFalse(EgressAllowlist.permits(host: "self-hosted.example"))

        EgressAllowlist.userConfiguredHost.set("Self-Hosted.Example")
        XCTAssertEqual(EgressAllowlist.userConfiguredHost.current(), "self-hosted.example")
        XCTAssertTrue(EgressAllowlist.permits(host: "self-hosted.example"))
        XCTAssertTrue(EgressAllowlist.permits(host: "SELF-HOSTED.EXAMPLE"))
        XCTAssertFalse(EgressAllowlist.permits(host: "telemetry.self-hosted.example"))
        XCTAssertFalse(EgressAllowlist.permits(host: "self-hosted.example.evil.net"))

        // The committed list is unaffected by whatever the user configured.
        XCTAssertTrue(EgressAllowlist.permits(host: "codeload.github.com"))

        EgressAllowlist.userConfiguredHost.set("")
        XCTAssertNil(EgressAllowlist.userConfiguredHost.current(), "an empty host must clear, not permit \"\"")
        XCTAssertFalse(EgressAllowlist.permits(host: "self-hosted.example"))
    }

    // MARK: - Page-driven markdown fetch

    /// Answers requests on `URLSession.shared` (the session the production
    /// markdown fetch uses) so nothing leaves the machine, and records which
    /// hosts got that far. Registered process-wide BEFORE `EgressGuard` so the
    /// guard — registered last, consulted first — decides ahead of it, exactly
    /// as `main.swift` arranges it around the rest of Foundation's transports.
    final class SharedTransport: URLProtocol {
        nonisolated(unsafe) static var receivedHosts: [String] = []
        private static let lock = NSLock()

        static func reset() {
            lock.withLock { receivedHosts = [] }
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            if let host = request.url?.host {
                Self.lock.withLock { Self.receivedHosts.append(host) }
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("# Qwave\n".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    /// Navigating to a `.md` document on a host that is not on
    /// `EgressAllowlist` must still render it. The destination is the URL the
    /// user asked for — WebKit has already fetched a response from it by the
    /// time `decidePolicyFor navigationResponse` hands the URL to
    /// `fetchAndPresentMarkdown` — so the allowlist, a list of hosts *Qwave*
    /// picked, has nothing to say about it. This drives the production
    /// coordinator on its production default session (`URLSession.shared`)
    /// with `EgressGuard` registered process-wide exactly as `main.swift`
    /// registers it, because that combination is what silently broke: the
    /// fetch was documented as ungated in four places while running on the one
    /// session global registration does reach.
    @MainActor
    func testRemoteMarkdownFetchOnNonAllowlistedHostIsNotBlocked() async throws {
        EgressGuard.onBlock.reset()
        SharedTransport.reset()
        URLProtocol.registerClass(SharedTransport.self)
        URLProtocol.registerClass(EgressGuard.self)
        defer {
            URLProtocol.unregisterClass(EgressGuard.self)
            URLProtocol.unregisterClass(SharedTransport.self)
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwave-markdown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let tab = Tab()
        let coordinator = NavigationCoordinator(
            tab: tab,
            shields: ShieldsDirector(
                compiler: RuleListCompiler(store: WKContentRuleListStore(url: dir)!),
                policy: ShieldsPolicy(directory: nil)
            ),
            httpsUpgrader: HTTPSFirstUpgrader(),
            history: nil,
            downloads: DownloadManager(directory: dir)
        )
        let url = URL(string: "https://raw.githubusercontent.com/8b-is/qwave/main/README.md")!
        XCTAssertFalse(
            EgressAllowlist.permits(host: url.host),
            "this test is only meaningful while raw.githubusercontent.com is off the allowlist"
        )

        await coordinator.fetchAndPresentMarkdown(url, in: WKWebView())

        XCTAssertTrue(
            EgressGuard.onBlock.hosts().isEmpty,
            "a page-driven markdown fetch must not be refused by EgressGuard — saw \(EgressGuard.onBlock.hosts())"
        )
        XCTAssertEqual(
            SharedTransport.receivedHosts, ["raw.githubusercontent.com"],
            "the markdown fetch must reach the transport"
        )
        XCTAssertEqual(tab.title, "README.md", "the fetched markdown must be presented, not an error page")
    }

    /// The carve-out is per **request**, not per session or per host: the very
    /// same URL, unmarked, on the very same session, is still refused. Without
    /// this, "markdown works again" could be bought by exempting a host or a
    /// whole session, which is a far larger hole than the one intended.
    func testPageDrivenExemptionDoesNotExemptTheHostOrTheSession() async throws {
        EgressGuard.onBlock.reset()
        StubTransport.reset()
        let session = makeGuardedSession()
        let url = URL(string: "https://raw.githubusercontent.com/8b-is/qwave/main/README.md")!

        let (_, response) = try await session.data(for: EgressGuard.markPageDriven(URLRequest(url: url)))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "a marked request must reach the transport")
        XCTAssertTrue(EgressGuard.onBlock.hosts().isEmpty)

        do {
            _ = try await session.data(for: URLRequest(url: url))
            XCTFail("an unmarked request to the same non-allowlisted host must still be blocked")
        } catch {
            XCTAssertEqual(
                EgressGuard.BlockedError(recovering: error)?.host, "raw.githubusercontent.com",
                "the unmarked request must be refused by EgressGuard, got \(error)"
            )
        }
        XCTAssertEqual(
            StubTransport.receivedHosts, ["raw.githubusercontent.com"],
            "exactly the marked request may reach the transport"
        )
    }

    /// Pins the reach of `URLProtocol.registerClass` itself, because
    /// mis-stating it is the root of the markdown regression: four documents
    /// said the guard intercepts "default- or shared-configuration sessions",
    /// which reads as though a fetch is safe unless it is on `.shared` — while
    /// the markdown fetch was on `.shared` all along. The truth is narrower in
    /// one direction and wider in the other: a session you construct is never
    /// reached, not even from `URLSessionConfiguration.default`, and
    /// `URLSession.shared` always is.
    ///
    /// `.invalid` is reserved by RFC 6761 and never resolves, so the
    /// constructed session's request fails at DNS rather than on the network —
    /// the assertion is that the failure is *not* ours.
    func testConstructedDefaultConfigurationSessionIsNotReachedByRegisterClass() async {
        EgressGuard.onBlock.reset()
        URLProtocol.registerClass(EgressGuard.self)
        defer { URLProtocol.unregisterClass(EgressGuard.self) }

        let url = URL(string: "https://qwave-egress-probe.invalid/x")!
        XCTAssertFalse(EgressAllowlist.permits(host: url.host))

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 5
        do {
            _ = try await URLSession(configuration: configuration).data(from: url)
            XCTFail("the probe host must not resolve")
        } catch {
            XCTAssertNil(
                EgressGuard.BlockedError(recovering: error),
                "a constructed default-configuration session must not consult the globally registered guard"
            )
        }
        XCTAssertTrue(
            EgressGuard.onBlock.hosts().isEmpty,
            "global registration must not reach a constructed session — saw \(EgressGuard.onBlock.hosts())"
        )
    }

    // MARK: - Capturing the suggestion request

    /// Records the URL of the one request the suggestion provider makes, and
    /// answers it locally so nothing leaves the machine.
    final class CapturedRequest: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: URL?

        func record(_ value: URL) {
            lock.withLock { recorded = value }
        }

        func url() -> URL? {
            lock.withLock { recorded }
        }
    }

    final class SuggestionCapture: URLProtocol {
        static let captured = CapturedRequest()

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url,
                let response = HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            else {
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            Self.captured.record(url)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("[]".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    // MARK: - No egress on the launch path

    /// A process-wide URLProtocol recorder: registered, it observes every
    /// `URLSession.shared` request and records the host without letting it
    /// leave the machine.
    final class RecorderState: @unchecked Sendable {
        private let lock = NSLock()
        private var recordedHosts: [String] = []

        func reset() {
            lock.withLock {
                recordedHosts = []
            }
        }

        func record(_ host: String) {
            lock.withLock {
                recordedHosts.append(host)
            }
        }

        func hosts() -> [String] {
            lock.withLock { recordedHosts }
        }
    }

    final class Recorder: URLProtocol {
        static let state = RecorderState()

        override class func canInit(with request: URLRequest) -> Bool {
            if let host = request.url?.host { state.record(host) }
            return false  // don't actually handle — just observe, let it fail closed
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    }

    @MainActor
    func testShieldsLaunchPathMakesNoNetworkRequest() async throws {
        Recorder.state.reset()
        URLProtocol.registerClass(Recorder.self)
        defer { URLProtocol.unregisterClass(Recorder.self) }

        // The always-on launch shields path, on a fresh rule-list store.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwave-egress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let director = ShieldsDirector(
            compiler: RuleListCompiler(store: WKContentRuleListStore(url: dir)!),
            policy: ShieldsPolicy(directory: nil)
        )
        await director.prepare()

        let hosts = Recorder.state.hosts()
        XCTAssertTrue(
            hosts.isEmpty,
            "shields launch preparation must make no network request — saw \(hosts)"
        )
    }
}
