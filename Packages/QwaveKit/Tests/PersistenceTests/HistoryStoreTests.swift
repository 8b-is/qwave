import XCTest
@testable import Persistence

final class HistoryStoreTests: XCTestCase {
    private func makeStore() throws -> HistoryStore {
        try HistoryStore(database: SQLiteDatabase())
    }

    func testRecordAndFetch() throws {
        let store = try makeStore()
        let url = URL(string: "https://example.com/")!
        try store.recordVisit(url: url, title: "Example", containerID: nil)

        let entries = try store.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].url, url)
        XCTAssertEqual(entries[0].title, "Example")
        XCTAssertEqual(entries[0].visitCount, 1)
    }

    func testRepeatVisitIncrementsCount() throws {
        let store = try makeStore()
        let url = URL(string: "https://example.com/")!
        try store.recordVisit(url: url, title: "Example", containerID: nil)
        try store.recordVisit(url: url, title: nil, containerID: nil)

        let entries = try store.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].visitCount, 2)
        XCTAssertEqual(entries[0].title, "Example", "Empty later title must not clobber the stored one")
    }

    func testContainerSeparation() throws {
        let store = try makeStore()
        let url = URL(string: "https://example.com/")!
        let container = UUID()
        try store.recordVisit(url: url, title: "Default", containerID: nil)
        try store.recordVisit(url: url, title: "Work", containerID: container)

        XCTAssertEqual(try store.entries().count, 2, "Same URL in different containers is two entries")

        try store.deleteAll(containerID: container)
        let remaining = try store.entries()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertNil(remaining[0].containerID)
    }

    func testSearchMatchesURLAndTitle() throws {
        let store = try makeStore()
        try store.recordVisit(url: URL(string: "https://swift.org/")!, title: "Swift", containerID: nil)
        try store.recordVisit(url: URL(string: "https://example.com/")!, title: "Nothing", containerID: nil)

        XCTAssertEqual(try store.entries(matching: "swift").count, 1)
        XCTAssertEqual(try store.entries(matching: "example").count, 1)
        XCTAssertEqual(try store.entries(matching: "zzz").count, 0)
    }

    func testDeleteAll() throws {
        let store = try makeStore()
        try store.recordVisit(url: URL(string: "https://a.example/")!, title: "A", containerID: nil)
        try store.recordVisit(url: URL(string: "https://b.example/")!, title: "B", containerID: nil)
        try store.deleteAll()
        XCTAssertTrue(try store.entries().isEmpty)
    }
}
