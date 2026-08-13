import XCTest
@testable import Persistence

final class HistoryStoreTests: XCTestCase {
    private func makeStore() async throws -> HistoryStore {
        try await HistoryStore(database: SQLiteDatabase())
    }

    func testRecordAndFetch() async throws {
        let store = try await makeStore()
        let url = URL(string: "https://example.com/")!
        try await store.recordVisit(url: url, title: "Example", containerID: nil)

        let entries = try await store.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].url, url)
        XCTAssertEqual(entries[0].title, "Example")
        XCTAssertEqual(entries[0].visitCount, 1)
    }

    func testRepeatVisitIncrementsCount() async throws {
        let store = try await makeStore()
        let url = URL(string: "https://example.com/")!
        try await store.recordVisit(url: url, title: "Example", containerID: nil)
        try await store.recordVisit(url: url, title: nil, containerID: nil)

        let entries = try await store.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].visitCount, 2)
        XCTAssertEqual(entries[0].title, "Example", "Empty later title must not clobber the stored one")
    }

    func testContainerSeparation() async throws {
        let store = try await makeStore()
        let url = URL(string: "https://example.com/")!
        let container = UUID()
        try await store.recordVisit(url: url, title: "Default", containerID: nil)
        try await store.recordVisit(url: url, title: "Work", containerID: container)

        let entries = try await store.entries()
        XCTAssertEqual(entries.count, 2, "Same URL in different containers is two entries")

        try await store.deleteAll(containerID: container)
        let remaining = try await store.entries()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertNil(remaining[0].containerID)
    }

    func testSearchMatchesURLAndTitle() async throws {
        let store = try await makeStore()
        try await store.recordVisit(url: URL(string: "https://swift.org/")!, title: "Swift", containerID: nil)
        try await store.recordVisit(url: URL(string: "https://example.com/")!, title: "Nothing", containerID: nil)

        let swiftEntries = try await store.entries(matching: "swift")
        let exampleEntries = try await store.entries(matching: "example")
        let missingEntries = try await store.entries(matching: "zzz")
        XCTAssertEqual(swiftEntries.count, 1)
        XCTAssertEqual(exampleEntries.count, 1)
        XCTAssertEqual(missingEntries.count, 0)
    }

    func testDeleteAll() async throws {
        let store = try await makeStore()
        try await store.recordVisit(url: URL(string: "https://a.example/")!, title: "A", containerID: nil)
        try await store.recordVisit(url: URL(string: "https://b.example/")!, title: "B", containerID: nil)
        try await store.deleteAll()
        let entries = try await store.entries()
        XCTAssertTrue(entries.isEmpty)
    }
}
