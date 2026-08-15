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
/// Three groups of checks, still narrower than they first look:
///  1. Three known Category-A endpoints are pinned to the committed
///     `EgressAllowlist` by the hand-written assertions below. Nothing
///     enumerates network call sites, so adding a new default endpoint
///     WITHOUT allowlisting it and wiring `EgressGuard` into its session does
///     not fail this test — a reviewer still has to notice.
///  2. `EgressGuard` runtime tests: a disallowed host is blocked when routed
///     through a session that installed the guard, an allowlisted host is
///     not, and the two production call sites (`URLSession.mullvadPinned()`,
///     `DuckDuckGoSuggestionProvider`'s default session) are asserted to
///     have installed it.
///  3. The always-on launch path (shields preparation) makes no URLSession
///     request — the launch-time blocklist fetch was removed. Scope: the
///     recorder below is installed with `URLProtocol.registerClass`, which
///     only intercepts sessions built from the default/shared configuration,
///     and this test drives a `ShieldsDirector` it constructs itself rather
///     than the app's launch sequence.
///
/// Honest scope: `EgressGuard` catches Category A (Qwave's own egress) for
/// any client that either uses a default-configuration session (covered by
/// the process-wide `URLProtocol.registerClass` in `main.swift`) or installs
/// it into a custom configuration explicitly (`EgressGuard.install(into:)`).
/// It does not cover a fixed-host client that skips that call, a
/// deliberately open-ended client (Memory Wave's user-configurable endpoint,
/// `FaviconLoader`, remote-markdown fetch — see `EgressGuard`'s doc comment),
/// Category B (page subresources), or Category C (WebKit's own network
/// process, e.g. the fraudulent-website warning). See docs/NETWORK.md.
final class EgressGuardTests: XCTestCase {

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
        } catch let error as EgressGuard.BlockedError {
            XCTAssertEqual(error.host, "evil.tracker.net")
        } catch {
            XCTFail("expected EgressGuard.BlockedError, got \(error)")
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
