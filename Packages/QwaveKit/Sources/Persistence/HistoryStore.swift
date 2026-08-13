import Foundation

public struct HistoryEntry: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let url: URL
    public let title: String
    public let visitCount: Int
    public let lastVisit: Date
    public let containerID: UUID?

    public init(id: Int64, url: URL, title: String, visitCount: Int, lastVisit: Date, containerID: UUID?) {
        self.id = id
        self.url = url
        self.title = title
        self.visitCount = visitCount
        self.lastVisit = lastVisit
        self.containerID = containerID
    }
}

/// Visit history, deduplicated by (url, container). Ephemeral containers never
/// reach this store — the caller simply doesn't record them.
///
/// The default container is stored as '' rather than NULL: SQLite UNIQUE
/// constraints treat NULLs as pairwise distinct, which would break the upsert.
public actor HistoryStore {
    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) async throws {
        self.database = database
        try await database.migrate([
            """
            CREATE TABLE IF NOT EXISTS history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                url TEXT NOT NULL,
                title TEXT NOT NULL DEFAULT '',
                visit_count INTEGER NOT NULL DEFAULT 1,
                last_visit REAL NOT NULL,
                container_id TEXT NOT NULL DEFAULT '',
                UNIQUE(url, container_id)
            );
            CREATE INDEX IF NOT EXISTS idx_history_last_visit ON history(last_visit DESC);
            CREATE INDEX IF NOT EXISTS idx_history_url ON history(url);
            CREATE INDEX IF NOT EXISTS idx_history_score ON history(visit_count DESC, last_visit DESC);
            """
        ])
    }

    private static func key(for containerID: UUID?) -> String {
        containerID?.uuidString ?? ""
    }

    public func recordVisit(url: URL, title: String?, containerID: UUID?, at date: Date = Date()) async throws {
        try await database.run(
            """
            INSERT INTO history (url, title, visit_count, last_visit, container_id)
            VALUES (?1, ?2, 1, ?3, ?4)
            ON CONFLICT(url, container_id) DO UPDATE SET
                visit_count = visit_count + 1,
                last_visit = excluded.last_visit,
                title = CASE WHEN excluded.title != '' THEN excluded.title ELSE history.title END
            """,
            [
                .text(url.absoluteString),
                .text(title ?? ""),
                .real(date.timeIntervalSince1970),
                .text(Self.key(for: containerID)),
            ]
        )
    }

    /// Updates the stored title for `url` (titles usually arrive after
    /// didFinish, later than the visit record).
    public func updateTitle(_ title: String, for url: URL, containerID: UUID?) async throws {
        guard !title.isEmpty else { return }
        try await database.run(
            "UPDATE history SET title = ?1 WHERE url = ?2 AND container_id = ?3",
            [
                .text(title),
                .text(url.absoluteString),
                .text(Self.key(for: containerID)),
            ]
        )
    }

    public func entries(matching query: String? = nil, limit: Int = 100) async throws -> [HistoryEntry] {
        let transform: (SQLiteRow) -> HistoryEntry? = { row in
            guard let urlString = row.text(1), let url = URL(string: urlString) else { return nil }
            let containerKey = row.text(5) ?? ""
            return HistoryEntry(
                id: row.int(0),
                url: url,
                title: row.text(2) ?? "",
                visitCount: Int(row.int(3)),
                lastVisit: Date(timeIntervalSince1970: row.double(4)),
                containerID: containerKey.isEmpty ? nil : UUID(uuidString: containerKey)
            )
        }
        let rows: [SQLiteRow]
        if let query, !query.isEmpty {
            rows = try await database.rows(
                """
                SELECT id, url, title, visit_count, last_visit, container_id FROM history
                WHERE url LIKE ?1 OR title LIKE ?1
                ORDER BY visit_count DESC, last_visit DESC LIMIT ?2
                """,
                [.text("%\(query)%"), .integer(Int64(limit))],
            )
        } else {
            rows = try await database.rows(
                """
                SELECT id, url, title, visit_count, last_visit, container_id FROM history
                ORDER BY last_visit DESC LIMIT ?1
                """,
                [.integer(Int64(limit))]
            )
        }
        return rows.compactMap(transform)
    }

    public func delete(id: Int64) async throws {
        try await database.run("DELETE FROM history WHERE id = ?1", [.integer(id)])
    }

    public func deleteAll() async throws {
        try await database.run("DELETE FROM history")
    }

    /// Removes all history recorded under a container (used when the container
    /// itself is deleted).
    public func deleteAll(containerID: UUID) async throws {
        try await database.run("DELETE FROM history WHERE container_id = ?1", [.text(containerID.uuidString)])
    }
}
