import CryptoKit
import Foundation
import Persistence
import QwaveSupport

/// Encrypted, container-scoped Cognitive memory. Wave frames sit in the
/// clear (no document text); title/url/body are AES-GCM sealed.
public actor MemoryStore {
    private let database: SQLiteDatabase
    private let key: SymmetricKey
    private var isPrepared = false

    /// Rows that failed to decode (bad `kind`/`lane`, unparsable wave frame,
    /// missing box, AES-GCM open failure, or non-UTF-8 plaintext) since this
    /// store was created. Never decremented. `records(...)` still returns
    /// only the rows that opened, so a caller that only checks the array's
    /// count cannot tell "no memories" from "every memory failed to open";
    /// this counter, plus the log line emitted alongside each drop, is the
    /// signal that distinguishes the two. See #84.
    public private(set) var droppedRowCount = 0

    public init(database: SQLiteDatabase, secrets: SecretStore) throws {
        self.database = database
        self.key = try MemoryCipher.loadOrCreateKey(in: secrets)
    }

    public init(directory: URL, secrets: SecretStore) throws {
        let url = directory.appendingPathComponent("memory-wave.db")
        self.database = try SQLiteDatabase(url: url)
        self.key = try MemoryCipher.loadOrCreateKey(in: secrets)
    }

    @discardableResult
    public func insert(
        title: String,
        body: String,
        url: URL?,
        kind: MemoryKind,
        lane: MemoryLane = .odd,
        containerID: UUID?,
        emotion: EmotionVector = .neutral,
        at date: Date = Date()
    ) async throws -> MemoryRecord {
        try await prepare()
        var pending = try makePendingInsert(
            title: title,
            body: body,
            url: url,
            kind: kind,
            lane: lane,
            containerID: containerID,
            emotion: emotion,
            date: date
        )
        pending.record.id = try await database.insertReturningRowID(Self.insertSQL, pending.parameters)
        return pending.record
    }

    /// Insert or refresh a browse wave for the same URL + container.
    @discardableResult
    public func upsertBrowse(
        title: String,
        body: String,
        url: URL,
        containerID: UUID?,
        emotion: EmotionVector = .neutral,
        at date: Date = Date()
    ) async throws -> MemoryRecord {
        try await prepare()
        var pending = try makePendingInsert(
            title: title,
            body: body,
            url: url,
            kind: .browse,
            lane: .odd,
            containerID: containerID,
            emotion: emotion,
            date: date
        )
        let containerKey = Self.key(for: containerID)
        let urlTag = MemoryCipher.hostTag(url.absoluteString, key: key)
        pending.record.id = try await database.replaceAndInsertReturningRowID(
            deleteSQL: "DELETE FROM memories WHERE container_id = ?1 AND kind = ?2 AND url_tag = ?3",
            deleteParameters: [.text(containerKey), .text(MemoryKind.browse.rawValue), .blob(urlTag)],
            insertSQL: Self.insertSQL,
            insertParameters: pending.parameters
        )
        return pending.record
    }

    public func records(since: Date? = nil, until: Date? = nil, limit: Int = 200) async throws -> [MemoryRecord] {
        try await prepare()
        var sql = """
            SELECT id, container_id, kind, lane, created, frame, title_box, body_box, url_box, signature_box
            FROM memories
            WHERE 1=1
            """
        var params: [SQLiteValue] = []
        if let since {
            params.append(.real(since.timeIntervalSince1970))
            sql += " AND created >= ?\(params.count)"
        }
        if let until {
            params.append(.real(until.timeIntervalSince1970))
            sql += " AND created <= ?\(params.count)"
        }
        params.append(.integer(Int64(limit)))
        sql += " ORDER BY created DESC LIMIT ?\(params.count)"
        return decodeAll(try await database.rows(sql, params))
    }

    public func records(containerID: UUID?, limit: Int = 32) async throws -> [MemoryRecord] {
        try await prepare()
        let rows = try await database.rows(
            """
            SELECT id, container_id, kind, lane, created, frame, title_box, body_box, url_box, signature_box
            FROM memories
            WHERE container_id = ?1
            ORDER BY created DESC
            LIMIT ?2
            """,
            [.text(Self.key(for: containerID)), .integer(Int64(limit))]
        )
        return decodeAll(rows)
    }

    public func grid(containerID: UUID?) async throws -> SparseWaveGrid {
        try await gridWithRecords(containerID: containerID).grid
    }

    /// The resonance grid together with the decoded records it was built from,
    /// so callers that also need the newest rows avoid a second decode of the
    /// same container.
    public func gridWithRecords(containerID: UUID?) async throws -> (
        grid: SparseWaveGrid, records: [MemoryRecord]
    ) {
        let records = try await records(containerID: containerID, limit: 256)
        var grid = SparseWaveGrid()
        for record in records {
            grid.insert(record.wave)
        }
        return (grid, records)
    }

    public func delete(id: Int64) async throws {
        try await prepare()
        try await database.run("DELETE FROM memories WHERE id = ?1", [.integer(id)])
    }

    public func deleteAll(containerID: UUID?) async throws {
        try await prepare()
        try await database.run(
            "DELETE FROM memories WHERE container_id = ?1",
            [.text(Self.key(for: containerID))]
        )
    }

    public func deleteAll() async throws {
        try await prepare()
        try await database.run("DELETE FROM memories")
    }

    /// Decodes a batch of rows, counting and logging any that fail rather
    /// than letting `compactMap` discard them invisibly. A single line at
    /// `.warning` after the batch tells a reader of the log (or of
    /// `droppedRowCount`) that a nonempty result set had losses, without
    /// spamming a line per row for the common all-good case. See #84.
    private func decodeAll(_ rows: [SQLiteRow]) -> [MemoryRecord] {
        var records: [MemoryRecord] = []
        records.reserveCapacity(rows.count)
        var dropped = 0
        for row in rows {
            if let record = decode(row) {
                records.append(record)
            } else {
                dropped += 1
            }
        }
        if dropped > 0 {
            droppedRowCount += dropped
            QwaveLog.memory.warning(
                """
                MemoryStore.decode dropped \(dropped) of \(rows.count) row(s) in this batch \
                (parse/decrypt/UTF-8 failure); total dropped since store init: \(droppedRowCount)
                """
            )
        }
        return records
    }

    private func decode(_ row: SQLiteRow) -> MemoryRecord? {
        let rowID = row.int(0)
        guard
            let kind = row.text(2).flatMap(MemoryKind.init(rawValue:)),
            let lane = row.text(3).flatMap(MemoryLane.init(rawValue:)),
            let frame = row.blob(5),
            case .success(let wave) = WaveInt.fromFrame(Array(frame)),
            let titleBox = row.blob(6),
            let bodyBox = row.blob(7),
            let sigBox = row.blob(9),
            let titleData = try? MemoryCipher.open(titleBox, key: key),
            let bodyData = try? MemoryCipher.open(bodyBox, key: key),
            // Authenticate the signature box as a fail-closed validity gate; its
            // plaintext is unused (the signature is recomputed from content below).
            (try? MemoryCipher.open(sigBox, key: key)) != nil,
            let title = String(data: titleData, encoding: .utf8),
            let body = String(data: bodyData, encoding: .utf8)
        else {
            // Row id is not sensitive (a SQLite rowid, not memory content);
            // it lets someone correlate this line with `deleteAll`/vacuum
            // decisions without decrypting anything.
            QwaveLog.memory.debug("MemoryStore.decode could not open row id \(rowID)")
            return nil
        }
        let url: URL?
        if let urlBox = row.blob(8), let urlData = try? MemoryCipher.open(urlBox, key: key) {
            url = String(data: urlData, encoding: .utf8).flatMap(URL.init(string:))
        } else {
            url = nil
        }
        let containerKey = row.text(1) ?? ""
        // MemoryRecord.signature is a computed property derived from title+body
        // (see MemoryRecord.swift), so it is not recomputed here. Doing so used
        // to cost a ~1000-step, 8-harmonic trig reconstruction per row for a
        // value no caller reads (issue #86).
        return MemoryRecord(
            id: row.int(0),
            containerID: containerKey.isEmpty ? nil : UUID(uuidString: containerKey),
            kind: kind,
            lane: lane,
            created: Date(timeIntervalSince1970: row.double(4)),
            url: url,
            title: title,
            body: body,
            wave: wave
        )
    }

    private static func key(for containerID: UUID?) -> String {
        containerID?.uuidString ?? ""
    }

    private static let insertSQL = """
        INSERT INTO memories
            (container_id, kind, lane, created, host_tag, frame, title_box, body_box, url_box, signature_box, url_tag)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
        """

    private struct PendingMemoryInsert {
        var record: MemoryRecord
        let parameters: [SQLiteValue]
    }

    private func makePendingInsert(
        title: String,
        body: String,
        url: URL?,
        kind: MemoryKind,
        lane: MemoryLane,
        containerID: UUID?,
        emotion: EmotionVector,
        date: Date
    ) throws -> PendingMemoryInsert {
        let payload = Data((title + "\n" + body).utf8)
        let identity =
            MemoryWaveConstants.consciousness.doubleValue
            * MemoryWaveConstants.goldenRatio.doubleValue
        let signature = WaveSignature.fromContent(payload, identityFrequency: identity)
        let nanos = WaveInt.nanosecondsSince1970(date)
        let wave = WaveInt(
            baseAmplitude: Rational(1, 1)!,
            frequency: frequencyRational(signature.dominantFrequency),
            phase: .zero,
            emotionalValence: emotion.valenceRational,
            arousal: emotion.arousalRational,
            createdAt: nanos,
            lastAccessed: nanos,
            accessCount: 1,
            decayRate: Rational(1, 10)!,
            id: nil,
            provenance: .cognitive
        )
        let titleBox = try MemoryCipher.seal(Data(title.utf8), key: key)
        let bodyBox = try MemoryCipher.seal(Data(body.utf8), key: key)
        let urlBox = try url.map { try MemoryCipher.seal(Data($0.absoluteString.utf8), key: key) }
        let signatureBox = try MemoryCipher.seal(Data(signature.interferenceHash), key: key)
        let hostTag = url.flatMap(\.host).map { MemoryCipher.hostTag($0, key: key) }
        let urlTag = url.map { MemoryCipher.hostTag($0.absoluteString, key: key) }
        let record = MemoryRecord(
            id: 0,
            containerID: containerID,
            kind: kind,
            lane: lane,
            created: date,
            url: url,
            title: title,
            body: body,
            wave: wave
        )
        return PendingMemoryInsert(
            record: record,
            parameters: [
                .text(Self.key(for: containerID)),
                .text(kind.rawValue),
                .text(lane.rawValue),
                .real(date.timeIntervalSince1970),
                hostTag.map(SQLiteValue.blob) ?? .null,
                .blob(Data(wave.toFrame())),
                .blob(titleBox),
                .blob(bodyBox),
                urlBox.map(SQLiteValue.blob) ?? .null,
                .blob(signatureBox),
                urlTag.map(SQLiteValue.blob) ?? .null,
            ]
        )
    }

    private func prepare() async throws {
        guard !isPrepared else { return }
        try await database.migrate([
            """
            CREATE TABLE IF NOT EXISTS memories (
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
            CREATE INDEX IF NOT EXISTS idx_memories_container_created
                ON memories(container_id, created DESC);
            """,
            """
            ALTER TABLE memories ADD COLUMN url_tag BLOB;
            CREATE INDEX IF NOT EXISTS idx_memories_url_tag
                ON memories(container_id, kind, url_tag);
            """,
        ])
        isPrepared = true
    }

    private func frequencyRational(_ hz: Double) -> Rational {
        let milli = Int32(clamping: Int((hz * 1000).rounded()))
        return Rational(max(1, milli), 1000) ?? MemoryWaveConstants.consciousness
    }
}
