import Foundation

public struct Bookmark: Identifiable, Equatable {
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

public final class BookmarkStore {
    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) throws {
        self.database = database
        try database.execute(
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
    public func add(title: String, url: URL, folder: String? = nil, at date: Date = Date()) throws -> Bookmark {
        try database.run(
            "INSERT INTO bookmarks (title, url, folder, created) VALUES (?1, ?2, ?3, ?4)",
            [
                .text(title),
                .text(url.absoluteString),
                folder.map(SQLiteValue.text) ?? .null,
                .real(date.timeIntervalSince1970),
            ]
        )
        return Bookmark(id: database.lastInsertRowID, title: title, url: url, folder: folder, created: date)
    }

    public func all() throws -> [Bookmark] {
        try database.query(
            "SELECT id, title, url, folder, created FROM bookmarks ORDER BY folder, created DESC"
        ) { row -> Bookmark? in
            guard let urlString = row.text(2), let url = URL(string: urlString) else { return nil }
            return Bookmark(
                id: row.int(0),
                title: row.text(1) ?? "",
                url: url,
                folder: row.text(3),
                created: Date(timeIntervalSince1970: row.double(4))
            )
        }
        .compactMap { $0 }
    }

    public func contains(url: URL) throws -> Bool {
        let count = try database.query(
            "SELECT COUNT(*) FROM bookmarks WHERE url = ?1",
            [.text(url.absoluteString)]
        ) { $0.int(0) }.first ?? 0
        return count > 0
    }

    public func delete(id: Int64) throws {
        try database.run("DELETE FROM bookmarks WHERE id = ?1", [.integer(id)])
    }

    public func rename(id: Int64, title: String) throws {
        try database.run("UPDATE bookmarks SET title = ?1 WHERE id = ?2", [.text(title), .integer(id)])
    }
}
