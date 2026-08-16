import Foundation
import MCP

/// The whole request surface, in one place, so the opt-in gate has exactly one
/// place to sit and cannot be walked around by adding a tool.
///
/// Both entry points (`listTools`, `callTool`) consult the gate first, and the
/// gate is re-read per call rather than captured at start-up so revoking
/// consent takes effect on a server process that is already running.
public actor QwaveMCPService {
    private let gate: MCPAccessGate
    private let reader: BrowserSnapshotReader
    private let encoder: JSONEncoder

    public init(gate: MCPAccessGate = MCPAccessGate(), reader: BrowserSnapshotReader = BrowserSnapshotReader()) {
        self.gate = gate
        self.reader = reader
        let encoder = JSONEncoder()
        // `.withoutEscapingSlashes` matters beyond looks: without it every URL
        // in the payload comes out as `https:\/\/…`, which quietly defeats any
        // caller — or test — that searches the response for a URL.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    public var isEnabled: Bool { gate.isEnabled }

    /// With the gate shut this advertises nothing — a disabled server should
    /// not read as a server with an empty history.
    public func listTools() -> [Tool] {
        gate.isEnabled ? QwaveMCPTools.all : []
    }

    public func callTool(name: String, arguments: [String: Value]?) async -> CallTool.Result {
        guard gate.isEnabled else {
            return Self.failure(MCPAccessGate.disabledMessage)
        }
        do {
            switch name {
            case QwaveMCPTools.searchHistoryName:
                guard let query = arguments?["query"]?.stringValue, !query.isEmpty else {
                    return Self.failure("`query` is required and must be a non-empty string.")
                }
                let rows = try await reader.searchHistory(
                    query: query, limit: QwaveMCPTools.resolvedLimit(from: arguments))
                return try encoded(rows)

            case QwaveMCPTools.recentHistoryName:
                let rows = try await reader.recentHistory(limit: QwaveMCPTools.resolvedLimit(from: arguments))
                return try encoded(rows)

            case QwaveMCPTools.listBookmarksName:
                return try encoded(try await reader.bookmarkList())

            case QwaveMCPTools.lastSavedSessionName:
                return try encoded(try await reader.lastSavedSession())

            default:
                return Self.failure("Unknown tool: \(name)")
            }
        } catch let error as BrowserSnapshotError {
            return Self.failure(Self.describe(error))
        } catch {
            return Self.failure("Qwave MCP read failed: \(error)")
        }
    }

    private func encoded<T: Encodable & Sendable>(_ value: T) throws -> CallTool.Result {
        let data = try encoder.encode(value)
        let text = String(decoding: data, as: UTF8.self)
        return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)])
    }

    private static func failure(_ message: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
    }

    private static func describe(_ error: BrowserSnapshotError) -> String {
        switch error {
        case .databaseMissing(let path):
            return "No Qwave profile database at \(path). Nothing was created; run Qwave at least once."
        case .sessionSnapshotMissing(let path):
            return "Qwave has never autosaved a session (\(path) does not exist)."
        case .sessionSnapshotUnreadable(let path):
            return "Qwave's saved session at \(path) could not be decoded."
        }
    }
}
