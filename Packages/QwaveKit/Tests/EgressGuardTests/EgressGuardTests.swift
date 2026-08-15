import WebKit
import XCTest

@testable import MemoryWave
@testable import QwaveSupport
@testable import Shields
@testable import VPNKit

/// The egress regression gate (docs/NETWORK.md, "prove what it sends").
///
/// Two checks, both narrower than they first look:
///  1. Known Category-A endpoints are pinned to the committed
///     `EgressAllowlist` by the hand-written assertions below. Nothing
///     enumerates network call sites, so adding a new default endpoint
///     WITHOUT allowlisting it does not fail this test (issue #77) — a
///     reviewer has to notice and add the assertion, as was missed for
///     `duckduckgo.com` until issue #78.
///  2. The always-on launch path (shields preparation) makes no URLSession
///     request — the launch-time blocklist fetch was removed. Scope: the
///     recorder below is installed with `URLProtocol.registerClass`, which
///     only intercepts sessions built from the default/shared configuration,
///     and this test drives a `ShieldsDirector` it constructs itself rather
///     than the app's launch sequence.
///
/// Honest scope: this catches Category A (Qwave's own egress) that goes
/// through a default-configuration `URLSession`. It cannot see a
/// custom-configuration session (e.g. the ephemeral DuckDuckGo suggestion
/// session, `FaviconLoader`), Category B (page subresources), or Category C
/// (WebKit's own network process, e.g. the fraudulent-website warning).
/// See docs/NETWORK.md.
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

    func testAllowlistRejectsUnknownHosts() {
        XCTAssertFalse(EgressAllowlist.permits(host: "example.com"))
        XCTAssertFalse(EgressAllowlist.permits(host: "evil.tracker.net"))
        XCTAssertFalse(EgressAllowlist.permits(host: nil))
        XCTAssertFalse(EgressAllowlist.permits(host: ""))
        // subdomain match works; sibling-domain confusion does not
        XCTAssertTrue(EgressAllowlist.permits(host: "codeload.github.com"))
        XCTAssertFalse(EgressAllowlist.permits(host: "github.com.evil.net"))
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
