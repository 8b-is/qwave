import Foundation
import SQLite3

public enum SQLiteError: Error {
    case openFailed(code: Int32, message: String)
    case prepareFailed(code: Int32, message: String, sql: String)
    case stepFailed(code: Int32, message: String)
    case bindFailed(code: Int32)
}

public enum SQLiteValue {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

/// Row accessor passed to query callbacks. Column indices are 0-based.
public struct SQLiteRow {
    let statement: OpaquePointer

    public func int(_ column: Int32) -> Int64 {
        sqlite3_column_int64(statement, column)
    }

    public func double(_ column: Int32) -> Double {
        sqlite3_column_double(statement, column)
    }

    public func text(_ column: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: cString)
    }

    public func blob(_ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        return Data(bytes: bytes, count: count)
    }

    public func isNull(_ column: Int32) -> Bool {
        sqlite3_column_type(statement, column) == SQLITE_NULL
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal serialized wrapper over the system SQLite. Not an ORM by design —
/// Qwave's stores are a handful of tables and this keeps the dependency
/// surface at zero (WireGuardKit stays the only third-party package).
public final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "is.8b.qwave.sqlite")

    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try open(path: url.path)
    }

    /// In-memory database for tests.
    public init() throws {
        try open(path: ":memory:")
    }

    private func open(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(path, &db, flags, nil)
        guard code == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let db { sqlite3_close_v2(db) }
            throw SQLiteError.openFailed(code: code, message: message)
        }
        handle = db
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA foreign_keys=ON;", nil, nil, nil)
    }

    deinit {
        if let handle {
            sqlite3_close_v2(handle)
        }
    }

    private func errorMessage() -> String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no database"
    }

    /// Executes one or more statements that take no parameters and return no rows.
    public func execute(_ sql: String) throws {
        try queue.sync {
            guard let handle else { return }
            let code = sqlite3_exec(handle, sql, nil, nil, nil)
            guard code == SQLITE_OK else {
                throw SQLiteError.stepFailed(code: code, message: errorMessage())
            }
        }
    }

    /// Runs a single parameterized statement that returns no rows.
    public func run(_ sql: String, _ params: [SQLiteValue] = []) throws {
        _ = try query(sql, params) { _ in () }
    }

    /// Runs a parameterized query, mapping each result row through `transform`.
    public func query<T>(
        _ sql: String,
        _ params: [SQLiteValue] = [],
        _ transform: (SQLiteRow) throws -> T
    ) throws -> [T] {
        try queue.sync {
            guard let handle else { return [] }
            var statement: OpaquePointer?
            let prepareCode = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
            guard prepareCode == SQLITE_OK, let statement else {
                throw SQLiteError.prepareFailed(code: prepareCode, message: errorMessage(), sql: sql)
            }
            defer { sqlite3_finalize(statement) }

            for (index, param) in params.enumerated() {
                let position = Int32(index + 1)
                let bindCode: Int32
                switch param {
                case .null:
                    bindCode = sqlite3_bind_null(statement, position)
                case .integer(let value):
                    bindCode = sqlite3_bind_int64(statement, position, value)
                case .real(let value):
                    bindCode = sqlite3_bind_double(statement, position, value)
                case .text(let value):
                    bindCode = sqlite3_bind_text(statement, position, value, -1, sqliteTransient)
                case .blob(let value):
                    bindCode = value.withUnsafeBytes { buffer in
                        sqlite3_bind_blob(statement, position, buffer.baseAddress, Int32(buffer.count), sqliteTransient)
                    }
                }
                guard bindCode == SQLITE_OK else {
                    throw SQLiteError.bindFailed(code: bindCode)
                }
            }

            var results: [T] = []
            while true {
                let stepCode = sqlite3_step(statement)
                if stepCode == SQLITE_ROW {
                    results.append(try transform(SQLiteRow(statement: statement)))
                } else if stepCode == SQLITE_DONE {
                    break
                } else {
                    throw SQLiteError.stepFailed(code: stepCode, message: errorMessage())
                }
            }
            return results
        }
    }

    public var lastInsertRowID: Int64 {
        queue.sync {
            guard let handle else { return 0 }
            return sqlite3_last_insert_rowid(handle)
        }
    }

    /// Schema-versioned migrations via PRAGMA user_version.
    public func migrate(_ migrations: [String]) throws {
        let current = try query("PRAGMA user_version") { row in row.int(0) }.first ?? 0
        guard current < Int64(migrations.count) else { return }
        for index in Int(current)..<migrations.count {
            try execute(migrations[index])
            try execute("PRAGMA user_version = \(index + 1)")
        }
    }
}
