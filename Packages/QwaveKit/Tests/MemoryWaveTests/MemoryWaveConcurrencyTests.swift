import Foundation
import Testing
@testable import MemoryWave
@testable import Persistence
import QwaveSupport

@Test func memoryStorePreservesContainerScopeAcrossSuspension() async throws {
    let store = try MemoryStore(database: SQLiteDatabase(), secrets: InMemorySecretStore())
    let containerID = UUID()

    _ = try await insertWorkMemory(into: store, containerID: containerID)
    await Task.yield()

    #expect(try await store.records(containerID: containerID).map(\.title) == ["Work"])
}

private func insertWorkMemory(
    into store: isolated MemoryStore,
    containerID: UUID
) async throws -> MemoryRecord {
    try await store.insert(
        title: "Work",
        body: "private note",
        url: URL(string: "https://example.com/a"),
        kind: .pin,
        containerID: containerID
    )
}

@Test func parallelBrowseUpsertsLeaveOneCurrentRecord() async throws {
    let store = try MemoryStore(database: SQLiteDatabase(), secrets: InMemorySecretStore())
    let url = URL(string: "https://example.com/current")!
    let updateCount = 64

    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0..<updateCount {
            group.addTask {
                _ = try await store.upsertBrowse(
                    title: "Update \(index)",
                    body: "Body \(index)",
                    url: url,
                    containerID: nil,
                    at: Date(timeIntervalSince1970: TimeInterval(index))
                )
            }
        }
        try await group.waitForAll()
    }

    let records = try await store.records(containerID: nil)
    #expect(records.count == 1)
    #expect(records[0].kind == .browse)
    #expect(records[0].url == url)
}

@Test func legacyV1DatabaseMigratesWhenMemoryStoreFirstUsesIt() async throws {
    let database = try SQLiteDatabase()
    try await database.execute(
        """
        CREATE TABLE memories (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            container_id TEXT NOT NULL DEFAULT '',
            kind TEXT NOT NULL,
            lane TEXT NOT NULL,
            created REAL NOT NULL,
            host_tag BLOB,
            frame BLOB NOT NULL,
            title_box BLOB NOT NULL,
            body_box BLOB NOT NULL,
            url_box BLOB,
            signature_box BLOB NOT NULL
        );
        CREATE INDEX idx_memories_container_created
            ON memories(container_id, created DESC);
        PRAGMA user_version = 1;
        """
    )
    let store = try MemoryStore(database: database, secrets: InMemorySecretStore())
    let url = URL(string: "https://example.com/legacy")!

    _ = try await store.upsertBrowse(
        title: "Migrated",
        body: "v1 rows receive the v2 url tag migration lazily",
        url: url,
        containerID: nil
    )

    let columns = try await database.rows("PRAGMA table_info(memories)")
    let records = try await store.records(containerID: nil)
    #expect(columns.contains { $0.text(1) == "url_tag" })
    #expect(records.map(\.title) == ["Migrated"])
}
