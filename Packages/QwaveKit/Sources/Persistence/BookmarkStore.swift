import Foundation

public struct Bookmark: Identifiable, Equatable, Sendable {
    public let id: Int64
    public var title: String
    public var url: URL
    public var folder: String?
    public let created: Date

    public init(id: Int64, title: String, url: URL, folder: String?, created: Date) {
        self.id = id
        self.title = title
        self.url = url
        self.folder = folder
        self.created = created
    }
}

public actor BookmarkStore {
    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) async throws {
        self.database = database
        try await database.execute(
            """
            CREATE TABLE IF NOT EXISTS bookmarks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                title TEXT NOT NULL,
                url TEXT NOT NULL,
                folder TEXT,
                created REAL NOT NULL
            );
            """
        )
    }

    @discardableResult
    public func add(title: String, url: URL, folder: String? = nil, at date: Date = Date()) async throws -> Bookmark {
        let id = try await database.insertReturningRowID(
            "INSERT INTO bookmarks (title, url, folder, created) VALUES (?1, ?2, ?3, ?4)",
            [
                .text(title),
                .text(url.absoluteString),
                folder.map(SQLiteValue.text) ?? .null,
                .real(date.timeIntervalSince1970),
            ]
        )
        return Bookmark(id: id, title: title, url: url, folder: folder, created: date)
    }

    public func all() async throws -> [Bookmark] {
        try await database.rows(
            "SELECT id, title, url, folder, created FROM bookmarks ORDER BY folder, created DESC"
        ).compactMap { row -> Bookmark? in
            guard let urlString = row.text(2), let url = URL(string: urlString) else { return nil }
            return Bookmark(
                id: row.int(0),
                title: row.text(1) ?? "",
                url: url,
                folder: row.text(3),
                created: Date(timeIntervalSince1970: row.double(4))
            )
        }
    }

    public func contains(url: URL) async throws -> Bool {
        let count =
            try await database.rows(
                "SELECT COUNT(*) FROM bookmarks WHERE url = ?1",
                [.text(url.absoluteString)]
            ).first?.int(0) ?? 0
        return count > 0
    }

    public func delete(id: Int64) async throws {
        try await database.run("DELETE FROM bookmarks WHERE id = ?1", [.integer(id)])
    }

    public func rename(id: Int64, title: String) async throws {
        try await database.run("UPDATE bookmarks SET title = ?1 WHERE id = ?2", [.text(title), .integer(id)])
    }
}
