import Foundation
import MCP

/// The tool catalogue. Four tools, each one backed by something an out-of-
/// process reader can genuinely see on disk; nothing here is a placeholder and
/// nothing here reports a value it did not read.
///
/// Every tool is annotated `readOnlyHint: true` / `openWorldHint: false`, which
/// is the literal truth: this server performs no writes and makes no network
/// request of any kind.
public enum QwaveMCPTools {
    public static let searchHistoryName = "qwave_search_history"
    public static let recentHistoryName = "qwave_recent_history"
    public static let listBookmarksName = "qwave_list_bookmarks"
    public static let lastSavedSessionName = "qwave_last_saved_session"

    /// Ceiling on rows returned in one call, applied to every history and
    /// bookmark query regardless of what the caller asks for.
    public static let maximumLimit = 500
    public static let defaultLimit = 50

    private static let readOnly = Tool.Annotations(
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    private static func limitProperty(_ description: String) -> Value {
        .object([
            "type": .string("integer"),
            "minimum": .int(1),
            "maximum": .int(maximumLimit),
            "default": .int(defaultLimit),
            "description": .string(description),
        ])
    }

    public static let all: [Tool] = [
        Tool(
            name: searchHistoryName,
            description: """
                Search the Qwave browser's visit history by substring, matched against both URL \
                and page title. Results are ranked by visit count, then recency. Rows are written \
                when a page finishes loading; private and ephemeral tabs are never recorded, so \
                they cannot appear here. Read-only.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("query")]),
                "additionalProperties": .bool(false),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "minLength": .int(1),
                        "description": .string("Substring to look for in the URL or the page title."),
                    ]),
                    "limit": limitProperty("Maximum rows to return (1-\(maximumLimit))."),
                ]),
            ]),
            annotations: readOnly
        ),
        Tool(
            name: recentHistoryName,
            description: """
                The most recently visited pages in the Qwave browser, newest first. Rows are \
                written when a page finishes loading; private and ephemeral tabs are never \
                recorded. This is history, not the set of tabs currently open. Read-only.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([
                    "limit": limitProperty("Maximum rows to return (1-\(maximumLimit)).")
                ]),
            ]),
            annotations: readOnly
        ),
        Tool(
            name: listBookmarksName,
            description: """
                Every bookmark saved in the Qwave browser, grouped by folder then newest first. \
                Written synchronously when the user saves a bookmark, so this is always current. \
                Read-only.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([:]),
            ]),
            annotations: readOnly
        ),
        Tool(
            name: lastSavedSessionName,
            description: """
                The Qwave browser's last AUTOSAVED window/tab snapshot — not its live tab set, \
                which no process outside the browser can observe. The result carries the \
                snapshot's timestamp, its age in seconds, and the caveats that apply: saves are \
                debounced about 2 seconds after activity and forced at most every 30 seconds, an \
                empty session is never written (so the file outlives the last closed window), and \
                private/ephemeral tabs are excluded. Returns each tab's URL, title and pinned \
                state only. Read-only.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([:]),
            ]),
            annotations: readOnly
        ),
    ]

    /// Clamps a caller-supplied `limit` into range. A missing or unusable value
    /// becomes the default rather than an error — but an enormous one is capped
    /// rather than honoured.
    public static func resolvedLimit(from arguments: [String: Value]?) -> Int {
        guard let raw = arguments?["limit"]?.intValue else { return defaultLimit }
        return min(max(raw, 1), maximumLimit)
    }
}
