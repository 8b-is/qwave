import XCTest
@testable import Persistence

final class FaviconStoreTests: XCTestCase {
    private func makeStore() async throws -> FaviconStore {
        try await FaviconStore(database: SQLiteDatabase())
    }

    func testStoreAndLoadFavicon() async throws {
        let store = try await makeStore()
        let fakePNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        try await store.store(host: "github.com", containerID: nil, data: fakePNG)

        let loaded = try await store.load(host: "github.com", containerID: nil)
        XCTAssertEqual(loaded, fakePNG)

        let missing = try await store.load(host: "apple.com", containerID: nil)
        XCTAssertNil(missing)
    }

    func testContainerIsolation() async throws {
        let store = try await makeStore()
        let icon1 = Data([0x01, 0x02])
        let icon2 = Data([0x03, 0x04])
        let workContainer = UUID()

        try await store.store(host: "example.com", containerID: nil, data: icon1)
        try await store.store(host: "example.com", containerID: workContainer, data: icon2)

        let defaultLoaded = try await store.load(host: "example.com", containerID: nil)
        let workLoaded = try await store.load(host: "example.com", containerID: workContainer)

        XCTAssertEqual(defaultLoaded, icon1)
        XCTAssertEqual(workLoaded, icon2)

        // Clear container icons
        try await store.clear(forContainer: workContainer)
        let clearedWork = try await store.load(host: "example.com", containerID: workContainer)
        let remainingDefault = try await store.load(host: "example.com", containerID: nil)
        XCTAssertNil(clearedWork)
        XCTAssertEqual(remainingDefault, icon1)
    }

    func testPruneOldIcons() async throws {
        let store = try await makeStore()
        let oldDate = Date(timeIntervalSince1970: 1000)
        let recentDate = Date(timeIntervalSince1970: 2000)
        let checkDate = Date(timeIntervalSince1970: 2500)

        try await store.store(host: "old.com", containerID: nil, data: Data([1]), at: oldDate)
        try await store.store(host: "new.com", containerID: nil, data: Data([2]), at: recentDate)

        // Prune older than 1000s from checkDate (cutoff = 1500)
        try await store.prune(olderThan: 1000, relativeTo: checkDate)

        let oldLoaded = try await store.load(host: "old.com", containerID: nil)
        let newLoaded = try await store.load(host: "new.com", containerID: nil)
        XCTAssertNil(oldLoaded)
        XCTAssertNotNil(newLoaded)
    }
}
