import XCTest
@testable import Persistence

final class SessionStoreTests: XCTestCase {
    func testRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwave-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try SessionStore(directory: dir)
        XCTAssertNil(store.load())

        let snapshot = SessionSnapshot(windows: [
            WindowSnapshot(
                tabs: [
                    TabSnapshot(url: URL(string: "https://example.com/"), title: "Example", containerID: nil, isPinned: true),
                    TabSnapshot(url: nil, title: "New Tab", containerID: UUID(), isPinned: false),
                ],
                selectedIndex: 1
            )
        ])
        try store.save(snapshot)

        let loaded = store.load()
        XCTAssertEqual(loaded?.windows, snapshot.windows)

        store.clear()
        XCTAssertNil(store.load())
    }
}
