import XCTest
@testable import Persistence

final class SessionStoreTests: XCTestCase {
    func testRoundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwave-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try await SessionStore(directory: dir)
        let emptySnapshot = await store.load()
        XCTAssertNil(emptySnapshot)

        let snapshot = SessionSnapshot(windows: [
            WindowSnapshot(
                tabs: [
                    TabSnapshot(
                        url: URL(string: "https://example.com/"), title: "Example", containerID: nil, isPinned: true),
                    TabSnapshot(url: nil, title: "New Tab", containerID: UUID(), isPinned: false),
                ],
                selectedIndex: 1
            )
        ])
        try await store.save(snapshot)

        let loaded = await store.load()
        XCTAssertEqual(loaded?.windows, snapshot.windows)

        await store.clear()
        let clearedSnapshot = await store.load()
        XCTAssertNil(clearedSnapshot)
    }
}
