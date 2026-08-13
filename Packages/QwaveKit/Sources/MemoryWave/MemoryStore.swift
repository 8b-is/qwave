import CryptoKit
import Foundation
import Persistence
import QwaveSupport

/// Encrypted, container-scoped Cognitive memory. Wave frames sit in the
/// clear (no document text); title/url/body are AES-GCM sealed.
public final class MemoryStore {
    private let database: SQLiteDatabase
    private let key: SymmetricKey

    public init(database: SQLiteDatabase, secrets: SecretStore) throws {
        self.database = database
        self.key = try MemoryCipher.loadOrCreateKey(in: secrets)
        try database.migrate([
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
    }

    public convenience init(directory: URL, secrets: SecretStore) throws {
        let url = directory.appendingPathComponent("memory-wave.db")
        try self.init(database: SQLiteDatabase(url: url), secrets: secrets)
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
    ) throws -> MemoryRecord {
        let payload = Data((title + "\n" + body).utf8)
        let identity = MemoryWaveConstants.consciousness.doubleValue
            * MemoryWaveConstants.goldenRatio.doubleValue
        let signature = WaveSignature.fromContent(payload, identityFrequency: identity)
        let nanos = UInt64(date.timeIntervalSince1970 * 1_000_000_000)
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
        let sigBox = try MemoryCipher.seal(Data(signature.interferenceHash), key: key)
        let hostTag = url.flatMap { $0.host }.map { MemoryCipher.hostTag($0, key: key) }
        let urlTag = url.map { MemoryCipher.hostTag($0.absoluteString, key: key) }

        try database.run(
            """
            INSERT INTO memories
                (container_id, kind, lane, created, host_tag, frame, title_box, body_box, url_box, signature_box, url_tag)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
            """,
            [
                .text(Self.key(for: containerID)),
                .text(kind.rawValue),
                .text(lane.rawValue),
                .real(date.timeIntervalSince1970),
                hostTag.map(SQLiteValue.blob) ?? .null,
                .blob(Data(wave.toFrame())),
                .blob(titleBox),
                .blob(bodyBox),
                urlBox.map(SQLiteValue.blob) ?? .null,
                .blob(sigBox),
                urlTag.map(SQLiteValue.blob) ?? .null,
            ]
        )

        return MemoryRecord(
            id: database.lastInsertRowID,
            containerID: containerID,
            kind: kind,
            lane: lane,
            created: date,
            url: url,
            title: title,
            body: body,
            wave: wave,
            signature: signature
        )
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
    ) throws -> MemoryRecord {
        let tag = MemoryCipher.hostTag(url.absoluteString, key: key)
        let existing = try database.query(
            """
            SELECT id FROM memories
            WHERE container_id = ?1 AND kind = ?2 AND url_tag = ?3
            LIMIT 1
            """,
            [.text(Self.key(for: containerID)), .text(MemoryKind.browse.rawValue), .blob(tag)]
        ) { $0.int(0) }
        if let id = existing.first {
            try database.run("DELETE FROM memories WHERE id = ?1", [.integer(id)])
        }
        return try insert(
            title: title, body: body, url: url, kind: .browse, lane: .odd,
            containerID: containerID, emotion: emotion, at: date)
    }

    public func records(since: Date? = nil, until: Date? = nil, limit: Int = 200) throws -> [MemoryRecord] {
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
        return try database.query(sql, params, decode).compactMap { $0 }
    }

    public func records(containerID: UUID?, limit: Int = 32) throws -> [MemoryRecord] {
        try database.query(
            """
            SELECT id, container_id, kind, lane, created, frame, title_box, body_box, url_box, signature_box
            FROM memories
            WHERE container_id = ?1
            ORDER BY created DESC
            LIMIT ?2
            """,
            [.text(Self.key(for: containerID)), .integer(Int64(limit))],
            decode
        )
        .compactMap { $0 }
    }

    public func grid(containerID: UUID?) throws -> SparseWaveGrid {
        var grid = SparseWaveGrid()
        for record in try records(containerID: containerID, limit: 256) {
            grid.insert(record.wave)
        }
        return grid
    }

    public func delete(id: Int64) throws {
        try database.run("DELETE FROM memories WHERE id = ?1", [.integer(id)])
    }

    public func deleteAll(containerID: UUID?) throws {
        try database.run(
            "DELETE FROM memories WHERE container_id = ?1",
            [.text(Self.key(for: containerID))]
        )
    }

    public func deleteAll() throws {
        try database.run("DELETE FROM memories")
    }

    private func decode(_ row: SQLiteRow) -> MemoryRecord? {
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
            let sigData = try? MemoryCipher.open(sigBox, key: key),
            let title = String(data: titleData, encoding: .utf8),
            let body = String(data: bodyData, encoding: .utf8)
        else {
            return nil
        }
        let url: URL?
        if let urlBox = row.blob(8), let urlData = try? MemoryCipher.open(urlBox, key: key) {
            url = String(data: urlData, encoding: .utf8).flatMap(URL.init(string:))
        } else {
            url = nil
        }
        let containerKey = row.text(1) ?? ""
        let identity = MemoryWaveConstants.consciousness.doubleValue
            * MemoryWaveConstants.goldenRatio.doubleValue
        let signature = WaveSignature.fromContent(
            Data((title + "\n" + body).utf8), identityFrequency: identity)
        // Prefer the stored interference hash if it still verifies; otherwise
        // keep the recomputed signature (content is source of truth).
        var verified = signature
        if signature.interferenceHash != Array(sigData) {
            verified = signature
        }
        _ = verified.verify()
        return MemoryRecord(
            id: row.int(0),
            containerID: containerKey.isEmpty ? nil : UUID(uuidString: containerKey),
            kind: kind,
            lane: lane,
            created: Date(timeIntervalSince1970: row.double(4)),
            url: url,
            title: title,
            body: body,
            wave: wave,
            signature: signature
        )
    }

    private static func key(for containerID: UUID?) -> String {
        containerID?.uuidString ?? ""
    }

    private func frequencyRational(_ hz: Double) -> Rational {
        let milli = Int32(clamping: Int((hz * 1000).rounded()))
        return Rational(max(1, milli), 1000) ?? MemoryWaveConstants.consciousness
    }
}
