import Foundation
import Logging
import os

/// Central loggers, one per subsystem area, all under the app's subsystem so
/// `log stream --predicate 'subsystem == "is.8b.qwave"'` captures everything.
///
/// The categories front swift-log (`Logging.Logger`) with an os_log backend.
/// Privacy is enforced *before* the message enters the swift-log pipeline:
/// swift-log flattens messages to plain strings, so redaction cannot be left
/// to the backend the way os_log interpolation privacy works. Interpolated
/// values are therefore classified at the call site — os.Logger-style
/// `\(value, privacy: .public)` syntax — and private values are replaced
/// with `<private>` in the emitted string. The default mirrors os_log's
/// `.auto`: numeric and boolean values stay visible, strings and objects
/// (URLs, hosts, error text) are redacted unless explicitly `.public`.
public enum QwaveLog {
    public static let subsystem = "is.8b.qwave"

    public static let browser = QwaveLogger(category: "browser")
    public static let shields = QwaveLogger(category: "shields")
    public static let energy = QwaveLogger(category: "energy")
    public static let features = QwaveLogger(category: "features")
    public static let vpn = QwaveLogger(category: "vpn")
    public static let persistence = QwaveLogger(category: "persistence")
    public static let tunnel = QwaveLogger(category: "tunnel")
    public static let memory = QwaveLogger(category: "memory")
}

/// Signposters for Instruments — hibernate/wake cycles show up as intervals
/// under the app's subsystem (Points of Interest / os_signpost instrument).
/// One signposter per category so a Speedometer capture groups the chrome-tax
/// suspects (energy tick, chrome refresh, shield reconciliation, web-view
/// cold start) as distinct Points-of-Interest lanes. See docs/PERF.md.
public enum QwaveSignposts {
    public static let energy = OSSignposter(subsystem: QwaveLog.subsystem, category: "energy")
    public static let browser = OSSignposter(subsystem: QwaveLog.subsystem, category: "browser")
    public static let shields = OSSignposter(subsystem: QwaveLog.subsystem, category: "shields")
    public static let coldstart = OSSignposter(subsystem: QwaveLog.subsystem, category: "coldstart")
}

// MARK: - Privacy-classified message

/// Mirrors the os_log privacy annotations Qwave call sites already use.
public enum QwaveLogPrivacy {
    case `public`
    case `private`
}

/// A log message whose interpolated values carry a privacy classification.
/// Rendering happens once, eagerly, into the redacted form — private data
/// never exists inside the logging pipeline.
public struct QwaveLogMessage: ExpressibleByStringInterpolation {
    /// The pipeline-safe rendering: private segments replaced by `<private>`.
    public let redactedDescription: String

    public init(stringLiteral value: String) {
        redactedDescription = value
    }

    public init(stringInterpolation: StringInterpolation) {
        redactedDescription = stringInterpolation.rendered
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        var rendered = ""

        public init(literalCapacity: Int, interpolationCount: Int) {
            rendered.reserveCapacity(literalCapacity + interpolationCount * 8)
        }

        public mutating func appendLiteral(_ literal: String) {
            rendered += literal
        }

        // `.auto` defaults, mirroring os_log: numbers/bools are visible,
        // strings and arbitrary objects are private.
        public mutating func appendInterpolation(_ value: some BinaryInteger) {
            rendered += String(describing: value)
        }

        public mutating func appendInterpolation(_ value: some BinaryFloatingPoint) {
            rendered += String(describing: value)
        }

        public mutating func appendInterpolation(_ value: Bool) {
            rendered += String(describing: value)
        }

        public mutating func appendInterpolation<T>(_ value: T) {
            rendered += "<private>"
        }

        public mutating func appendInterpolation<T>(_ value: T, privacy: QwaveLogPrivacy) {
            switch privacy {
            case .public:
                rendered += String(describing: value)
            case .private:
                rendered += "<private>"
            }
        }
    }
}

// MARK: - Category logger

/// One category's logger: the stable Qwave-facing API in front of swift-log.
public struct QwaveLogger: Sendable {
    private let logger: Logging.Logger

    /// Production logger: swift-log front-end, os_log backend. Built with the
    /// per-logger factory escape hatch instead of `LoggingSystem.bootstrap`,
    /// which is once-per-process and would fight the test runner.
    public init(category: String) {
        self.init(category: category) { label in
            OSLogBackend(label: label, subsystem: QwaveLog.subsystem, category: category)
        }
    }

    /// Injection point for tests (spy handlers).
    init(category: String, factory: (String) -> any LogHandler) {
        logger = Logging.Logger(label: "\(QwaveLog.subsystem).\(category)", factory: factory)
    }

    public func debug(_ message: @autoclosure () -> QwaveLogMessage) {
        logger.debug(pipelineMessage(message()))
    }

    public func info(_ message: @autoclosure () -> QwaveLogMessage) {
        logger.info(pipelineMessage(message()))
    }

    public func warning(_ message: @autoclosure () -> QwaveLogMessage) {
        logger.warning(pipelineMessage(message()))
    }

    public func error(_ message: @autoclosure () -> QwaveLogMessage) {
        logger.error(pipelineMessage(message()))
    }

    private func pipelineMessage(_ message: QwaveLogMessage) -> Logging.Logger.Message {
        .init(stringLiteral: message.redactedDescription)
    }
}

// MARK: - os_log backend

/// swift-log handler forwarding to `os.Logger`. The forwarded string is
/// already redacted (see `QwaveLogMessage`), so it is logged `.public`;
/// os_log-level redaction would otherwise blank entire lines, including the
/// parts call sites explicitly marked public.
struct OSLogBackend: LogHandler {
    /// `os.Logger` predates Sendable annotations but is documented
    /// thread-safe; the box confines the unchecked conformance to one place.
    private final class Sink: @unchecked Sendable {
        let logger: os.Logger
        init(subsystem: String, category: String) {
            logger = os.Logger(subsystem: subsystem, category: category)
        }
    }

    private let sink: Sink

    var logLevel: Logging.Logger.Level = .debug
    var metadata: Logging.Logger.Metadata = [:]
    var metadataProvider: Logging.Logger.MetadataProvider?

    init(label: String, subsystem: String, category: String) {
        sink = Sink(subsystem: subsystem, category: category)
    }

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logging.Logger.Level,
        message: Logging.Logger.Message,
        metadata explicitMetadata: Logging.Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        var merged = self.metadata
        if let provided = metadataProvider?.get() {
            merged.merge(provided) { _, provided in provided }
        }
        if let explicitMetadata {
            merged.merge(explicitMetadata) { _, explicit in explicit }
        }

        var text = message.description
        if !merged.isEmpty {
            let pairs =
                merged
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            text += " [\(pairs)]"
        }

        sink.logger.log(level: Self.osLogType(for: level), "\(text, privacy: .public)")
    }

    /// warning → .default follows Apple's own swift-log→os_log bridge; only
    /// error/critical persist as error-class entries.
    static func osLogType(for level: Logging.Logger.Level) -> OSLogType {
        switch level {
        case .trace, .debug: return .debug
        case .info: return .info
        case .notice, .warning: return .default
        case .error: return .error
        case .critical: return .fault
        }
    }
}
