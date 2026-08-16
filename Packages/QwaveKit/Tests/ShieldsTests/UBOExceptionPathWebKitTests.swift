import XCTest
import Network
import WebKit

@testable import Shields

/// Issue #139: `@@||host/path^` exceptions compiled cleanly and could never
/// match, because the optional port group was written *after* the path.
///
/// The reason that survived is the whole point of this file. Every check the
/// exception path had was a compile check — the rule count went up, WebKit
/// accepted the list, nothing errored — and a rule that compiles is
/// indistinguishable, from the outside, from a rule that works. So nothing
/// here reads a pattern. A real WKWebView loads a real page from a real
/// loopback server with a real compiled `WKContentRuleList` attached, and the
/// assertion is on **which requests reached the socket**.
///
/// Both halves of the proof are here permanently, not just in a PR:
/// `testExceptionWithAPathSuppressesAMatchingRequest` is green only with the
/// fix, and `testTheLegacyExceptionShapeNeverSuppressedAnything` compiles the
/// pre-fix pattern verbatim and shows the same request being blocked. A revert
/// turns the first red; a "fix" that does not change behaviour turns the
/// second red.
final class UBOExceptionPathWebKitTests: XCTestCase {

    // MARK: - The pre-fix regex, verbatim

    /// `UBORuleListCompiler.filter`'s exception branch as it stood before this
    /// change: the whole `host/path` tail handed to `anchoredHostRegex` as if
    /// it were a host, so the port group and the authority's slash land after
    /// the path.
    static func legacyExceptionURLFilter(_ pattern: String) -> String {
        pattern.hasPrefix("||")
            ? UBORuleListCompiler.anchoredHostRegex(host: String(pattern.dropFirst(2)))
            : NSRegularExpression.escapedPattern(for: pattern)
    }

    // MARK: - Fixtures

    /// Blocks everything under `/probe/`, then allows one file back.
    private static let blockingLine = "||127.0.0.1/probe/"
    private static let exceptionPattern = "||127.0.0.1/probe/allowed.gif"

    private static let blockedPath = "/probe/blocked.gif"
    private static let allowedPath = "/probe/allowed.gif"
    /// Outside `/probe/`, so no rule touches it, and last in document order —
    /// its arrival means the two above have already been dispatched or dropped.
    private static let sentinelPath = "/sentinel.gif"

    // MARK: - Tests

    /// The fix, measured: the exception actually suppresses the block, and only
    /// for the file it names.
    @MainActor
    func testExceptionWithAPathSuppressesAMatchingRequest() async throws {
        let (json, _, exceptions, _) = UBORuleListCompiler.compileJSON(
            from: "\(Self.blockingLine)\n@@\(Self.exceptionPattern)^")
        XCTAssertEqual(exceptions, 1)

        let reached = try await requestsReachingTheServer(withRuleList: json)

        XCTAssertTrue(
            reached.contains(Self.allowedPath),
            "the @@||host/path^ exception did not fire — reached: \(reached.sorted())")
        XCTAssertFalse(
            reached.contains(Self.blockedPath),
            "the blocking rule did not fire, so the test proves nothing — reached: \(reached.sorted())")
    }

    /// The same request, the same server, the same blocking rule — with the
    /// exception's url-filter written the pre-fix way. It never fires, so the
    /// request is blocked. This is the red half of the proof, kept executable.
    @MainActor
    func testTheLegacyExceptionShapeNeverSuppressedAnything() async throws {
        let legacy = Self.legacyExceptionURLFilter(Self.exceptionPattern)
        XCTAssertTrue(
            legacy.hasSuffix("(:[0-9]+)?/"),
            "the legacy shape no longer ends in the misplaced port group: \(legacy)")

        let (blocking, _, _, _) = UBORuleListCompiler.compileJSON(from: Self.blockingLine)
        let json = Self.spliceException(legacy, into: blocking)

        let reached = try await requestsReachingTheServer(withRuleList: json)

        XCTAssertFalse(
            reached.contains(Self.allowedPath),
            "the legacy exception suppressed a request — re-derive #139, the defect is gone")
        XCTAssertFalse(reached.contains(Self.blockedPath))
    }

    /// And the same pattern through `NSRegularExpression`, so a failure above
    /// can be told apart from a WebKit or networking problem: the legacy regex
    /// does not match the URL, the fixed one does.
    func testTheTwoPatternsAgainstTheURLTheProbeActuallyRequests() throws {
        let url = "http://127.0.0.1:8443\(Self.allowedPath)"
        let legacy = Self.legacyExceptionURLFilter(Self.exceptionPattern)
        let fixed = try Self.urlFilter(ofExceptionIn: "@@\(Self.exceptionPattern)^")

        XCTAssertFalse(Self.matches(legacy, url), "legacy: \(legacy)")
        XCTAssertTrue(Self.matches(fixed, url), "fixed: \(fixed)")
        // Not even without a port: the trailing `/` the authority contributed
        // is still stranded after the path.
        XCTAssertFalse(Self.matches(legacy, "http://127.0.0.1\(Self.allowedPath)"))
        XCTAssertTrue(Self.matches(fixed, "http://127.0.0.1\(Self.allowedPath)"))
        // The port group is back where `anchoredHostRegex` puts it.
        XCTAssertTrue(fixed.hasPrefix(UBORuleListCompiler.anchoredHostRegex(host: "127.0.0.1")), fixed)
    }

    /// The exception is still narrower than the block it overrides: a sibling
    /// under the same directory stays blocked. Without this, "the exception
    /// fires" would also be satisfied by an exception that matches everything.
    func testTheFixedExceptionDoesNotWidenToSiblings() throws {
        let fixed = try Self.urlFilter(ofExceptionIn: "@@\(Self.exceptionPattern)^")
        XCTAssertTrue(Self.matches(fixed, "http://127.0.0.1:8443\(Self.allowedPath)"))
        XCTAssertFalse(Self.matches(fixed, "http://127.0.0.1:8443\(Self.blockedPath)"))
        XCTAssertFalse(Self.matches(fixed, "http://127.0.0.1:8443/other/allowed.gif"))
        XCTAssertFalse(Self.matches(fixed, "http://evil.example/127.0.0.1/probe/allowed.gif"))
        // Subdomains of a host still count, as they do for a blocking rule.
        let host = try Self.urlFilter(ofExceptionIn: "@@||example.com/path^")
        XCTAssertTrue(Self.matches(host, "https://cdn.example.com:8443/path/x"))
        XCTAssertFalse(Self.matches(host, "https://example.com.evil.test/path"))
    }

    // MARK: - Driving a real request through WebKit

    /// Loads `http://127.0.0.1:<port>/` in a WKWebView carrying `ruleListJSON`
    /// and returns the paths that actually reached the loopback socket.
    @MainActor
    private func requestsReachingTheServer(withRuleList ruleListJSON: String) async throws -> Set<String> {
        let server = try LoopbackProbeServer(
            page: """
                <!doctype html><meta charset="utf-8"><title>probe</title>
                <img src="\(Self.blockedPath)"><img src="\(Self.allowedPath)">
                <img src="\(Self.sentinelPath)">
                """)
        defer { server.stop() }
        let port = try await server.start()

        let ruleList = try await compileRuleList(ruleListJSON)

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(ruleList)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let delegate = NavigationWaiter()
        webView.navigationDelegate = delegate

        webView.load(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!))
        try await delegate.waitForLoad(timeout: 30)

        // The sentinel is last in document order and matches no rule, so its
        // arrival means the parser has already dispatched (or the engine has
        // already dropped) the two images above it. The settle after it is
        // slack for the connections finishing out of order, not for the
        // decision itself.
        try await server.waitForPath(Self.sentinelPath, timeout: 30)
        try await Task.sleep(nanoseconds: 500_000_000)

        // Proof the harness itself works: the document arrived, and so did the
        // image no rule touches (`waitForPath` above would have thrown).
        let reached = server.recordedPaths
        XCTAssertTrue(reached.contains("/"), "the probe page never loaded — reached: \(reached.sorted())")
        return reached
    }

    @MainActor
    private func compileRuleList(_ json: String) async throws -> WKContentRuleList {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwave-ubo-139-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Not a `defer`: the compiled list is backed by this directory for as
        // long as the web view holds it.
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let store = try XCTUnwrap(WKContentRuleListStore(url: dir))
        let compiled: CompiledRuleList = await withCheckedContinuation { continuation in
            store.compileContentRuleList(forIdentifier: "issue139-\(UUID().uuidString)", encodedContentRuleList: json) {
                list, error in
                continuation.resume(
                    returning: CompiledRuleList(
                        list: list,
                        failure: (error as NSError?).map {
                            ($0.userInfo[NSHelpAnchorErrorKey] as? String) ?? $0.description
                        }))
            }
        }
        return try XCTUnwrap(compiled.list, "WebKit rejected the rule list: \(compiled.failure ?? "no reason")")
    }

    /// `WKContentRuleList` is not `Sendable`, and the compile callback lands
    /// off the awaiting context. Boxed rather than made `Sendable`-by-assertion
    /// anywhere wider: the value is produced on WebKit's callback thread and
    /// consumed on the main actor, and nothing else touches it.
    private struct CompiledRuleList: @unchecked Sendable {
        let list: WKContentRuleList?
        let failure: String?
    }

    // MARK: - Helpers

    /// WebKit's url-filter is a search, like `NSRegularExpression.firstMatch`.
    private static func matches(_ pattern: String, _ string: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        return expression.firstMatch(in: string, range: NSRange(location: 0, length: (string as NSString).length))
            != nil
    }

    /// The `url-filter` the compiler emits for the single exception in `line`.
    private static func urlFilter(ofExceptionIn line: String) throws -> String {
        let (json, _, _, _) = UBORuleListCompiler.compileJSON(from: line)
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        let trigger = try XCTUnwrap(rules.last?["trigger"] as? [String: Any])
        return try XCTUnwrap(trigger["url-filter"] as? String)
    }

    /// Appends an `ignore-previous-rules` rule carrying `urlFilter` verbatim to
    /// an already-compiled document, so the legacy pattern can be run through
    /// WebKit without keeping a copy of the old compiler around.
    private static func spliceException(_ urlFilter: String, into json: String) -> String {
        let escaped = urlFilter.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "/", with: "\\/")
        let exception = "{\"trigger\":{\"url-filter\":\"\(escaped)\"},\"action\":{\"type\":\"ignore-previous-rules\"}}"
        return "\(json.dropLast()),\(exception)]"
    }
}

// MARK: - Navigation waiter

/// `didFinish`/`didFail` as an awaitable. WKWebView calls these on the main
/// actor, which is where the test lives.
@MainActor
private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, any Error>?
    private var outcome: Result<Void, any Error>?

    func waitForLoad(timeout: TimeInterval) async throws {
        let deadline = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self.finish(.failure(URLError(.timedOut)))
        }
        defer { deadline.cancel() }
        if let outcome { return try outcome.get() }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    private func finish(_ result: Result<Void, any Error>) {
        guard outcome == nil else { return }
        outcome = result
        continuation?.resume(with: result)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finish(.failure(error))
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
    ) {
        finish(.failure(error))
    }
}

// MARK: - Loopback probe server

/// A one-page HTTP server bound to 127.0.0.1 that records the paths requested
/// of it. Deliberately not a general HTTP implementation: it answers `GET`,
/// closes the connection, and remembers what it was asked for. The recording
/// is the measurement — a request that a content rule list suppressed never
/// reaches here.
private final class LoopbackProbeServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "qwave.ubo.probe")
    private let lock = NSLock()
    private var paths: Set<String> = []
    private let page: String

    /// A 1x1 transparent GIF — the smallest thing that is unambiguously an
    /// image load rather than a document load.
    private static let pixel = Data(
        base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")!

    init(page: String) throws {
        self.page = page
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Bound to loopback explicitly: an `.any` bind asks macOS for the
        // "accept incoming network connections" prompt on a developer machine.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    var recordedPaths: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            connection.start(queue: self.queue)
            self.receive(connection, buffer: Data())
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let resumed = Resumed()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: resumed.once { continuation.resume() }
                case .failed(let error): resumed.once { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        guard let port = listener.port?.rawValue else { throw URLError(.cannotConnectToHost) }
        return port
    }

    func stop() {
        listener.cancel()
    }

    /// Polls rather than signalling: the recorder runs on the listener queue
    /// and the caller is on the main actor, and a poll keeps the whole
    /// hand-off out of the measurement.
    func waitForPath(_ path: String, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if recordedPaths.contains(path) { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw URLError(.timedOut)
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete || error != nil { return connection.cancel() }
                return self.receive(connection, buffer: buffer)
            }
            let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
            let requestLine = head.split(separator: "\r\n").first ?? ""
            let target = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            self.lock.lock()
            self.paths.insert(target)
            self.lock.unlock()
            connection.send(
                content: self.response(for: target),
                completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func response(for path: String) -> Data {
        let isDocument = path == "/"
        let body = isDocument ? Data(page.utf8) : Self.pixel
        let head = """
            HTTP/1.1 200 OK\r
            Content-Type: \(isDocument ? "text/html; charset=utf-8" : "image/gif")\r
            Content-Length: \(body.count)\r
            Cache-Control: no-store\r
            Connection: close\r
            \r

            """
        return Data(head.utf8) + body
    }
}

/// One-shot guard for an `NWListener` state handler, which can fire more than
/// once. `@unchecked Sendable` around a lock: the handler is not isolated.
private final class Resumed: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func once(_ body: () -> Void) {
        lock.lock()
        let alreadyDone = done
        done = true
        lock.unlock()
        if !alreadyDone { body() }
    }
}
