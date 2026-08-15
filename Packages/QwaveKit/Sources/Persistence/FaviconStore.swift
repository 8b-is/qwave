import Foundation

/// A persistent, container-isolated SQLite store for website favicons.
///
/// Stores compressed image data (PNG/WebP) keyed by `(host, container_id)`.
/// Non-persistent/ephemeral containers are kept in-memory and never written to disk.
public actor FaviconStore {
    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) async throws {
        self.database = database
        try await database.migrate([
            """
            CREATE TABLE IF NOT EXISTS favicons (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                host TEXT NOT NULL,
                container_id TEXT NOT NULL DEFAULT '',
                icon_data BLOB NOT NULL,
                updated_at REAL NOT NULL,
                UNIQUE(host, container_id)
            );
            CREATE INDEX IF NOT EXISTS idx_favicons_host ON favicons(host, container_id);
            CREATE INDEX IF NOT EXISTS idx_favicons_updated ON favicons(updated_at DESC);
            """
        ])
    }

    private static func containerKey(_ containerID: UUID?) -> String {
        containerID?.uuidString ?? ""
    }

    /// Persists favicon data for the given host and container.
    public func store(host: String, containerID: UUID?, data: Data, at date: Date = Date()) async throws {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedHost.isEmpty, !data.isEmpty else { return }
        let cKey = Self.containerKey(containerID)

        try await database.run(
            """
            INSERT INTO favicons (host, container_id, icon_data, updated_at)
            VALUES (?1, ?2, ?3, ?4)
            ON CONFLICT(host, container_id) DO UPDATE SET
                icon_data = excluded.icon_data,
                updated_at = excluded.updated_at;
            """,
            [.text(normalizedHost), .text(cKey), .blob(data), .real(date.timeIntervalSince1970)]
        )
    }

    /// Loads the stored favicon bytes for a given host and container.
    public func load(host: String, containerID: UUID?) async throws -> Data? {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedHost.isEmpty else { return nil }
        let cKey = Self.containerKey(containerID)

        let rows = try await database.rows(
            """
            SELECT icon_data FROM favicons
            WHERE host = ?1 AND container_id = ?2
            LIMIT 1;
            """,
            [.text(normalizedHost), .text(cKey)]
        )

        guard let first = rows.first, let blob = first.blob(0) else {
            return nil
        }
        return blob
    }

    /// Deletes all favicons associated with a specific container.
    public func clear(forContainer containerID: UUID?) async throws {
        let cKey = Self.containerKey(containerID)
        try await database.run(
            """
            DELETE FROM favicons WHERE container_id = ?1;
            """,
            [.text(cKey)]
        )
    }

    /// Prunes icons not updated within the specified retention window.
    public func prune(olderThan interval: TimeInterval, relativeTo date: Date = Date()) async throws {
        let cutoff = date.timeIntervalSince1970 - interval
        try await database.run(
            """
            DELETE FROM favicons WHERE updated_at < ?1;
            """,
            [.real(cutoff)]
        )
    }
}
