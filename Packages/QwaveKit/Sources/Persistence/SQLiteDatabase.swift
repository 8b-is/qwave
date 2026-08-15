import Foundation
import SQLite3

public enum SQLiteError: Error, Sendable {
    case openFailed(code: Int32, message: String)
    case prepareFailed(code: Int32, message: String, sql: String)
    case stepFailed(code: Int32, message: String)
    case bindFailed(code: Int32)
}

public enum SQLiteValue: Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

/// A copied query row. SQLite statements stay inside `SQLiteDatabase` and
/// values can safely cross its actor boundary.
public struct SQLiteRow: Sendable {
    private let values: [SQLiteValue]

    init(values: [SQLiteValue]) {
        self.values = values
    }

    public func int(_ column: Int32) -> Int64 {
        switch values[Int(column)] {
        case .integer(let value): return value
        case .real(let value): return Int64(value)
        default: return 0
        }
    }

    public func double(_ column: Int32) -> Double {
        switch values[Int(column)] {
        case .integer(let value): return Double(value)
        case .real(let value): return value
        default: return 0
        }
    }

    public func text(_ column: Int32) -> String? {
        guard case .text(let value) = values[Int(column)] else { return nil }
        return value
    }

    public func blob(_ column: Int32) -> Data? {
        guard case .blob(let value) = values[Int(column)] else { return nil }
        return value
    }

    public func isNull(_ column: Int32) -> Bool {
        if case .null = values[Int(column)] { return true }
        return false
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private final class SQLiteConnection {
    let handle: OpaquePointer
    var statementCache: [String: OpaquePointer] = [:]

    init(path: String) throws {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(path, &database, flags, nil)
        guard code == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let database { sqlite3_close_v2(database) }
            throw SQLiteError.openFailed(code: code, message: message)
        }
        handle = database
        // Apple Silicon & Unified Memory Ultra-Performance Tuning:
        // - WAL mode for non-blocking concurrent reads + single writer
        // - NORMAL synchronous to eliminate redundant NVMe fsync stalls while preserving ACID
        // - MEMORY temp_store to avoid temporary disk spill on high-cardinality searches
        // - 256MB direct mmap for zero-copy unified memory virtual address mapping
        // - 64MB page cache for instantaneous omnibox history lookups
        // - 5000ms busy timeout to gracefully handle concurrent container operations
        // - Multi-threaded sorting across performance cores
        sqlite3_exec(database, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(database, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
        sqlite3_exec(database, "PRAGMA temp_store=MEMORY;", nil, nil, nil)
        sqlite3_exec(database, "PRAGMA mmap_size=268435456;", nil, nil, nil)
        sqlite3_exec(database, "PRAGMA cache_size=-64000;", nil, nil, nil)
        sqlite3_exec(database, "PRAGMA busy_timeout=5000;", nil, nil, nil)
        sqlite3_exec(database, "PRAGMA threads=4;", nil, nil, nil)
        sqlite3_exec(database, "PRAGMA foreign_keys=ON;", nil, nil, nil)
    }

    deinit {
        sqlite3_exec(handle, "PRAGMA optimize;", nil, nil, nil)
        for statement in statementCache.values {
            sqlite3_finalize(statement)
        }
        sqlite3_close_v2(handle)
    }
}

/// Minimal serialized wrapper over system SQLite. The database handle and
/// prepared-statement cache never leave this actor.
public actor SQLiteDatabase {
    private let connection: SQLiteConnection
    /// Caches prepared statements keyed by SQL text so the hottest queries
    /// (HistoryStore on every keystroke) skip sqlite3_prepare_v2 overhead.
    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        connection = try SQLiteConnection(path: url.path)
    }

    /// In-memory database for tests.
    public init() throws {
        connection = try SQLiteConnection(path: ":memory:")
    }

    private func errorMessage() -> String {
        String(cString: sqlite3_errmsg(connection.handle))
    }

    /// Returns a cached prepared statement for `sql`, or prepares and caches one.
    private func cachedStatement(_ sql: String) throws -> OpaquePointer {
        if let cached = connection.statementCache[sql] {
            sqlite3_reset(cached)
            sqlite3_clear_bindings(cached)
            return cached
        }
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(connection.handle, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else {
            throw SQLiteError.prepareFailed(code: code, message: errorMessage(), sql: sql)
        }
        connection.statementCache[sql] = statement
        return statement
    }

    /// Executes one or more statements that take no parameters and return no rows.
    public func execute(_ sql: String) throws {
        let code = sqlite3_exec(connection.handle, sql, nil, nil, nil)
        guard code == SQLITE_OK else {
            throw SQLiteError.stepFailed(code: code, message: errorMessage())
        }
    }

    /// Runs a single parameterized statement that returns no rows.
    public func run(_ sql: String, _ params: [SQLiteValue] = []) throws {
        _ = try rows(sql, params)
    }

    /// Executes an insert and captures its SQLite row id before the actor can
    /// service another database operation.
    public func insertReturningRowID(_ sql: String, _ params: [SQLiteValue] = []) throws -> Int64 {
        try run(sql, params)
        return sqlite3_last_insert_rowid(connection.handle)
    }

    /// Replaces matching rows and inserts a new row without yielding the
    /// database actor between those operations.
    public func replaceAndInsertReturningRowID(
        deleteSQL: String,
        deleteParameters: [SQLiteValue],
        insertSQL: String,
        insertParameters: [SQLiteValue]
    ) throws -> Int64 {
        try run(deleteSQL, deleteParameters)
        return try insertReturningRowID(insertSQL, insertParameters)
    }

    /// Runs a parameterized query and returns copied values, never SQLite-backed
    /// statement state.
    public func rows(_ sql: String, _ params: [SQLiteValue] = []) throws -> [SQLiteRow] {
        let statement = try cachedStatement(sql)

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

        var results: [SQLiteRow] = []
        while true {
            let stepCode = sqlite3_step(statement)
            if stepCode == SQLITE_ROW {
                results.append(copyRow(from: statement))
            } else if stepCode == SQLITE_DONE {
                break
            } else {
                throw SQLiteError.stepFailed(code: stepCode, message: errorMessage())
            }
        }
        return results
    }

    /// Runs SQLite query planner optimization to refresh statistics and indices.
    public func optimize() throws {
        try execute("PRAGMA optimize;")
    }

    /// Schema-versioned migrations via PRAGMA user_version.
    public func migrate(_ migrations: [String]) throws {
        let current = try rows("PRAGMA user_version").first?.int(0) ?? 0
        guard current < Int64(migrations.count) else { return }
        for index in Int(current)..<migrations.count {
            try execute(migrations[index])
            try execute("PRAGMA user_version = \(index + 1)")
        }
    }

    private func copyRow(from statement: OpaquePointer) -> SQLiteRow {
        let columnCount = sqlite3_column_count(statement)
        var values: [SQLiteValue] = []
        values.reserveCapacity(Int(columnCount))
        for column in 0..<columnCount {
            switch sqlite3_column_type(statement, column) {
            case SQLITE_INTEGER:
                values.append(.integer(sqlite3_column_int64(statement, column)))
            case SQLITE_FLOAT:
                values.append(.real(sqlite3_column_double(statement, column)))
            case SQLITE_TEXT:
                values.append(.text(String(cString: sqlite3_column_text(statement, column))))
            case SQLITE_BLOB:
                let count = Int(sqlite3_column_bytes(statement, column))
                if count == 0 {
                    values.append(.blob(Data()))
                } else {
                    values.append(.blob(Data(bytes: sqlite3_column_blob(statement, column), count: count)))
                }
            default:
                values.append(.null)
            }
        }
        return SQLiteRow(values: values)
    }
}
