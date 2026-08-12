import XCTest
@testable import Persistence

final class BookmarkStoreTests: XCTestCase {
    func testAddContainsDelete() throws {
        let store = try BookmarkStore(database: SQLiteDatabase())
        let url = URL(string: "https://webkit.org/")!

        XCTAssertFalse(try store.contains(url: url))
        let bookmark = try store.add(title: "WebKit", url: url, folder: "Dev")
        XCTAssertTrue(try store.contains(url: url))

        let all = try store.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].title, "WebKit")
        XCTAssertEqual(all[0].folder, "Dev")

        try store.rename(id: bookmark.id, title: "WebKit Blog")
        XCTAssertEqual(try store.all()[0].title, "WebKit Blog")

        try store.delete(id: bookmark.id)
        XCTAssertFalse(try store.contains(url: url))
    }
}
