import XCTest
@testable import Persistence

final class BookmarkStoreTests: XCTestCase {
    func testAddContainsDelete() async throws {
        let store = try await BookmarkStore(database: SQLiteDatabase())
        let url = URL(string: "https://webkit.org/")!

        let initiallyContains = try await store.contains(url: url)
        XCTAssertFalse(initiallyContains)
        let bookmark = try await store.add(title: "WebKit", url: url, folder: "Dev")
        let containsBookmark = try await store.contains(url: url)
        XCTAssertTrue(containsBookmark)

        let all = try await store.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].title, "WebKit")
        XCTAssertEqual(all[0].folder, "Dev")

        try await store.rename(id: bookmark.id, title: "WebKit Blog")
        let renamed = try await store.all()
        XCTAssertEqual(renamed[0].title, "WebKit Blog")

        try await store.delete(id: bookmark.id)
        let containsAfterDelete = try await store.contains(url: url)
        XCTAssertFalse(containsAfterDelete)
    }
}
