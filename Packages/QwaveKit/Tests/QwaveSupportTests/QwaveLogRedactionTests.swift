import XCTest
import Logging
@testable import QwaveSupport

/// The privacy contract from the v0.3.0 kickoff: browser URLs (and any other
/// string/object data) must reach the logging pipeline already redacted;
/// only values explicitly marked `.public` — and bare numerics, mirroring
/// os_log's `.auto` — stay visible.
final class QwaveLogRedactionTests: XCTestCase {
    func testStringInterpolationIsPrivateByDefault() {
        let url = "https://secret.example/account?id=42"
        let message: QwaveLogMessage = "visited \(url) status \(200)"
        XCTAssertEqual(message.redactedDescription, "visited <private> status 200")
    }

    func testExplicitPublicStaysVisible() {
        let host = "example.com"
        let message: QwaveLogMessage = "fallback to \(host, privacy: .public)"
        XCTAssertEqual(message.redactedDescription, "fallback to example.com")
    }

    func testExplicitPrivateRedactsAnything() {
        let message: QwaveLogMessage = "count \(42, privacy: .private)"
        XCTAssertEqual(message.redactedDescription, "count <private>")
    }

    func testObjectsArePrivateByDefault() {
        let id = UUID()
        let message: QwaveLogMessage = "tab \(id) closed"
        XCTAssertEqual(message.redactedDescription, "tab <private> closed")
        XCTAssertFalse(message.redactedDescription.contains(id.uuidString))
    }

    /// End to end: a URL logged through a category logger must be redacted in
    /// the message the backend receives.
    func testLoggerEmitsRedactedMessageToHandler() {
        final class Spy: @unchecked Sendable {
            var messages: [String] = []
        }
        struct SpyHandler: LogHandler {
            let spy: Spy
            var logLevel: Logging.Logger.Level = .trace
            var metadata: Logging.Logger.Metadata = [:]
            var metadataProvider: Logging.Logger.MetadataProvider?
            subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
                get { metadata[key] }
                set { metadata[key] = newValue }
            }
            func log(
                level: Logging.Logger.Level,
                message: Logging.Logger.Message,
                metadata: Logging.Logger.Metadata?,
                source: String,
                file: String,
                function: String,
                line: UInt
            ) {
                spy.messages.append(message.description)
            }
        }

        let spy = Spy()
        let logger = QwaveLogger(category: "test") { _ in SpyHandler(spy: spy) }

        let url = URL(string: "https://secret.example/private/path")!
        logger.info("navigating to \(url.absoluteString)")
        logger.error("blocked \("tracker.example", privacy: .public) on \(url.absoluteString)")

        XCTAssertEqual(spy.messages.count, 2)
        XCTAssertEqual(spy.messages[0], "navigating to <private>")
        XCTAssertEqual(spy.messages[1], "blocked tracker.example on <private>")
        XCTAssertFalse(spy.messages.joined().contains("secret.example"))
    }

    func testOSLogTypeMapping() {
        XCTAssertEqual(OSLogBackend.osLogType(for: .trace), .debug)
        XCTAssertEqual(OSLogBackend.osLogType(for: .debug), .debug)
        XCTAssertEqual(OSLogBackend.osLogType(for: .info), .info)
        XCTAssertEqual(OSLogBackend.osLogType(for: .notice), .default)
        XCTAssertEqual(OSLogBackend.osLogType(for: .warning), .default)
        XCTAssertEqual(OSLogBackend.osLogType(for: .error), .error)
        XCTAssertEqual(OSLogBackend.osLogType(for: .critical), .fault)
    }
}
