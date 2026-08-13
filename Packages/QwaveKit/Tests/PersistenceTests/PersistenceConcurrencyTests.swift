import Foundation
import Testing
@testable import Persistence

@Test func bookmarkActorPreservesStateAcrossSuspension() async throws {
    let store = try await BookmarkStore(database: SQLiteDatabase())
    let url = URL(string: "https://webkit.org/")!

    let bookmark = try await store.add(title: "WebKit", url: url, folder: "Dev")
    await Task.yield()

    #expect(try await store.contains(url: url))
    #expect(try await store.all().map(\.id) == [bookmark.id])
}

@Test func sessionStorePreservesSavedSnapshotAcrossSuspension() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("qwave-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = try await SessionStore(directory: directory)
    let snapshot = SessionSnapshot(windows: [WindowSnapshot(tabs: [], selectedIndex: 0)])
    try await store.save(snapshot)
    await Task.yield()

    #expect(await store.load() == snapshot)
}

@Test func sharedDatabaseReturnsDistinctIDsForParallelBookmarkInserts() async throws {
    let database = try SQLiteDatabase()
    let insertCount = 64
    var stores: [BookmarkStore] = []
    for _ in 0..<insertCount {
        stores.append(try await BookmarkStore(database: database))
    }

    let bookmarks = try await withThrowingTaskGroup(of: Bookmark.self, returning: [Bookmark].self) { group in
        for (index, store) in stores.enumerated() {
            group.addTask {
                try await store.add(
                    title: "Bookmark \(index)",
                    url: URL(string: "https://example.com/\(index)")!
                )
            }
        }
        var results: [Bookmark] = []
        for try await bookmark in group {
            results.append(bookmark)
        }
        return results
    }

    #expect(Set(bookmarks.map(\.id)).count == insertCount)
}

@Test func cachedStatementsClearAndRebindParameters() async throws {
    let database = try SQLiteDatabase()
    try await database.execute("CREATE TABLE bindings (id INTEGER PRIMARY KEY, value TEXT NOT NULL)")

    let firstID = try await database.insertReturningRowID(
        "INSERT INTO bindings (id, value) VALUES (?1, ?2)",
        [.integer(1), .text("first")]
    )
    let secondID = try await database.insertReturningRowID(
        "INSERT INTO bindings (id, value) VALUES (?1, ?2)",
        [.integer(2), .text("second")]
    )
    let firstRows = try await database.rows("SELECT value FROM bindings WHERE id = ?1", [.integer(1)])
    let secondRows = try await database.rows("SELECT value FROM bindings WHERE id = ?1", [.integer(2)])

    #expect(firstID == 1)
    #expect(secondID == 2)
    #expect(firstRows.first?.text(0) == "first")
    #expect(secondRows.first?.text(0) == "second")
}
