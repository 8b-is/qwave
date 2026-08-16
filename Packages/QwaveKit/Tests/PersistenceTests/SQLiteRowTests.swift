import Foundation
import Testing

@testable import Persistence

/// Rows of one result set share a single value buffer (#141), so the thing
/// worth testing is that a row still reads only its OWN columns. A row that
/// misindexed by one column would return its neighbour's value rather than
/// crash, which is exactly the kind of bug that reads as "data corruption"
/// three layers up.
@Test func rowsInAResultSetDoNotReadEachOthersColumns() async throws {
    let database = try SQLiteDatabase()
    try await database.execute(
        """
        CREATE TABLE mixed (
            id INTEGER PRIMARY KEY,
            label TEXT NOT NULL,
            weight REAL NOT NULL,
            payload BLOB,
            note TEXT
        );
        """
    )
    for index in 0..<25 {
        try await database.run(
            "INSERT INTO mixed (id, label, weight, payload, note) VALUES (?1, ?2, ?3, ?4, ?5)",
            [
                .integer(Int64(index)),
                .text("label-\(index)-padded-well-past-the-small-string-limit"),
                .real(Double(index) * 1.5),
                .blob(Data([UInt8(index), UInt8(index &+ 1)])),
                index.isMultiple(of: 2) ? .null : .text("note-\(index)"),
            ]
        )
    }

    let rows = try await database.rows("SELECT id, label, weight, payload, note FROM mixed ORDER BY id")
    #expect(rows.count == 25)
    for (index, row) in rows.enumerated() {
        #expect(row.int(0) == Int64(index))
        #expect(row.text(1) == "label-\(index)-padded-well-past-the-small-string-limit")
        #expect(row.double(2) == Double(index) * 1.5)
        #expect(row.blob(3) == Data([UInt8(index), UInt8(index &+ 1)]))
        if index.isMultiple(of: 2) {
            #expect(row.isNull(4))
            #expect(row.text(4) == nil)
        } else {
            #expect(row.text(4) == "note-\(index)")
        }
    }
}

/// A row must stay readable after the result set that produced it has gone out
/// of scope — the shared buffer is kept alive by the rows, not by the array.
@Test func aRowOutlivesTheResultSetArray() async throws {
    let database = try SQLiteDatabase()
    try await database.execute("CREATE TABLE t (a TEXT NOT NULL, b TEXT NOT NULL);")
    try await database.run("INSERT INTO t (a, b) VALUES (?1, ?2)", [.text("first"), .text("second")])
    try await database.run("INSERT INTO t (a, b) VALUES (?1, ?2)", [.text("third"), .text("fourth")])

    // Ascending on `a` is "first" then "third", so index 1 is the second row.
    let second = try await database.rows("SELECT a, b FROM t ORDER BY a")[1]
    #expect(second.text(0) == "third")
    #expect(second.text(1) == "fourth")
}
