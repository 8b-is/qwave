import CryptoKit
import XCTest
@testable import MemoryWave
import Persistence
import QwaveSupport

final class RationalTests: XCTestCase {
    func testRejectsZeroDenominator() {
        XCTAssertNil(Rational(1, 0))
    }

    func testReduces() {
        let r = Rational(4, 8)
        XCTAssertEqual(r?.num, 1)
        XCTAssertEqual(r?.den, 2)
    }

    func testEqualityAfterReduction() {
        XCTAssertEqual(Rational(2, 4), Rational(1, 2))
    }
}

final class WaveIntFrameTests: XCTestCase {
    func testRoundTrip() throws {
        let wave = WaveInt(
            baseAmplitude: Rational(1, 2)!,
            frequency: Rational(73, 100)!,
            phase: Rational(1, 4)!,
            emotionalValence: Rational(-1, 2)!,
            arousal: Rational(3, 10)!,
            createdAt: 1_700_000_000_000_000_000,
            lastAccessed: 1_700_000_000_000_000_001,
            accessCount: 7,
            decayRate: Rational(1, 10)!,
            id: 42,
            provenance: .cognitive
        )
        let frame = wave.toFrame()
        XCTAssertEqual(frame.count, 79)
        switch WaveInt.fromFrame(frame) {
        case .success(let decoded):
            XCTAssertEqual(decoded, wave)
        case .failure(let error):
            XCTFail("round-trip failed: \(error)")
        }
    }

    func testRejectsUnknownProvenance() {
        var frame = WaveInt(
            baseAmplitude: .one,
            frequency: MemoryWaveConstants.consciousness,
            phase: .zero,
            emotionalValence: .zero,
            arousal: Rational(1, 2)!,
            createdAt: 1,
            lastAccessed: 1,
            accessCount: 0,
            decayRate: Rational(1, 10)!,
            id: nil,
            provenance: .cognitive
        ).toFrame()
        frame[1] = 0xFF
        frame[78] = frame.prefix(78).reduce(0, ^)
        if case .failure(let error) = WaveInt.fromFrame(frame) {
            XCTAssertEqual(error, .invalidProvenance)
        } else {
            XCTFail("hostile provenance must not enter the grid")
        }
    }

    func testChecksumCatchesFlip() {
        var frame = WaveInt(
            baseAmplitude: .one,
            frequency: MemoryWaveConstants.consciousness,
            phase: .zero,
            emotionalValence: .zero,
            arousal: Rational(1, 2)!,
            createdAt: 1,
            lastAccessed: 1,
            accessCount: 0,
            decayRate: Rational(1, 10)!,
            id: nil,
            provenance: .cognitive
        ).toFrame()
        frame[10] ^= 0x01
        if case .failure(let error) = WaveInt.fromFrame(frame) {
            XCTAssertEqual(error, .checksumMismatch)
        } else {
            XCTFail("tampered frame must be rejected")
        }
    }

    func testCognitiveNeverEqualsNexus() {
        XCTAssertNotEqual(WaveProvenance.cognitive.rawValue, WaveProvenance.nexus.rawValue)
    }
}

final class WaveSignatureTests: XCTestCase {
    func testVerifyAndTamper() {
        let sig = WaveSignature.fromContent(Data("hello waves".utf8), identityFrequency: 0.73 * 1.618)
        XCTAssertTrue(sig.verify())
        var broken = sig
        broken.amplitudes[0] += 0.05
        XCTAssertFalse(broken.verify())
    }

    func testDeterministic() {
        let a = WaveSignature.fromContent(Data("same".utf8), identityFrequency: 1.0)
        let b = WaveSignature.fromContent(Data("same".utf8), identityFrequency: 1.0)
        XCTAssertEqual(a.interferenceHash, b.interferenceHash)
    }
}

final class SparseWaveGridTests: XCTestCase {
    func testResonanceRanksCloserFrequencyFirst() {
        var grid = SparseWaveGrid()
        let near = makeWave(freq: Rational(80, 100)!, valence: .zero)
        let far = makeWave(freq: Rational(200, 100)!, valence: .zero)
        grid.insert(near)
        grid.insert(far)
        let query = makeWave(freq: Rational(73, 100)!, valence: .zero)
        let ranked = grid.resonate(query: query, radius: 64)
        XCTAssertGreaterThanOrEqual(ranked.count, 1)
        XCTAssertEqual(ranked.first?.1.frequency, near.frequency)
    }

    private func makeWave(freq: Rational, valence: Rational) -> WaveInt {
        WaveInt(
            baseAmplitude: .one,
            frequency: freq,
            phase: .zero,
            emotionalValence: valence,
            arousal: Rational(1, 2)!,
            createdAt: 1,
            lastAccessed: 1,
            accessCount: 0,
            decayRate: Rational(1, 10)!,
            id: nil,
            provenance: .cognitive
        )
    }
}

final class MarineDetectorTests: XCTestCase {
    func testPeriodicSignalOutranksSpike() {
        var periodic = MarineDetector()
        var peak = 0.0
        for i in 0..<64 {
            let sample = sin(Double(i) * .pi / 4.0)
            peak = max(peak, periodic.process(sample: sample))
        }
        var spike = MarineDetector()
        _ = spike.process(sample: 0)
        _ = spike.process(sample: 1)
        _ = spike.process(sample: 0)
        XCTAssertGreaterThan(peak, spike.salience)
    }

    func testTextScoreIsBounded() {
        let score = MarineDetector.score(text: "The wave remembers what the vector forgets.")
        XCTAssertGreaterThanOrEqual(score, 0)
        XCTAssertLessThanOrEqual(score, 1)
    }
}

final class SemanticVectorTests: XCTestCase {
    func testIdenticalVectorsAreMaximallySimilar() {
        let a = SemanticVector([0.2, 0.9, -0.4, 0.1])
        XCTAssertEqual(a.cosineSimilarity(to: a), 1.0, accuracy: 1e-6)
    }

    func testOrthogonalVectorsScoreZero() {
        let a = SemanticVector([1, 0, 0])
        let b = SemanticVector([0, 1, 0])
        XCTAssertEqual(a.cosineSimilarity(to: b), 0.0, accuracy: 1e-6)
    }

    func testOppositeVectorsScoreNegativeOne() {
        let a = SemanticVector([0.5, 0.5])
        let b = SemanticVector([-0.5, -0.5])
        XCTAssertEqual(a.cosineSimilarity(to: b), -1.0, accuracy: 1e-6)
    }

    func testMismatchedDimensionsScoreZero() {
        let a = SemanticVector([1, 0, 0])
        let b = SemanticVector([1, 0])
        XCTAssertEqual(a.cosineSimilarity(to: b), 0.0)
    }
}

final class SemanticRerankerTests: XCTestCase {
    func testRerankOrdersByCosineSimilarity() {
        let query = SemanticVector([1, 0, 0])
        let candidates: [(item: String, vector: SemanticVector?)] = [
            ("far", SemanticVector([0, 1, 0])),
            ("near", SemanticVector([0.9, 0.1, 0])),
            ("mid", SemanticVector([0.5, 0.5, 0])),
        ]
        XCTAssertEqual(SemanticReranker.rerank(query: query, candidates: candidates), ["near", "mid", "far"])
    }

    func testUnembeddedCandidatesKeepLexicalOrderAtTail() {
        let query = SemanticVector([1, 0])
        let candidates: [(item: String, vector: SemanticVector?)] = [
            ("lexA", nil),
            ("scored", SemanticVector([0.8, 0.2])),
            ("lexB", nil),
        ]
        // Scored candidate leads; the two nil-embedding rows preserve input order.
        XCTAssertEqual(SemanticReranker.rerank(query: query, candidates: candidates), ["scored", "lexA", "lexB"])
    }

    func testAllUnembeddedFallsBackToLexicalOrder() {
        let query = SemanticVector([1, 0])
        let candidates: [(item: String, vector: SemanticVector?)] = [
            ("first", nil),
            ("second", nil),
            ("third", nil),
        ]
        XCTAssertEqual(SemanticReranker.rerank(query: query, candidates: candidates), ["first", "second", "third"])
    }
}

@MainActor
final class SemanticRecallTests: XCTestCase {
    func testRecallWithoutEmbedderFallsBackToLexical() async throws {
        let secrets = InMemorySecretStore()
        let store = try MemoryStore(database: SQLiteDatabase(), secrets: secrets)
        let prefs = MemoryWavePreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!, secrets: secrets)
        // Passing embedder: nil disables the semantic path — recall stays lexical.
        let director = WaveDirector(store: store, preferences: prefs, embedder: nil)
        _ = try await director.remember(
            title: "Wave memory", body: "resonance and recall", url: nil,
            containerID: nil, isEphemeral: false)
        let hits = try await director.recall(containerID: nil, query: "recall", limit: 8)
        XCTAssertFalse(hits.isEmpty)
    }

    /// Issue #110: `recall` built its rank map with
    /// `Dictionary(uniqueKeysWithValues:)` keyed on the nanosecond
    /// `createdAt`, which traps the process when two records share one
    /// caller-supplied timestamp. Identical content + identical `at:` is the
    /// extreme case — the two waves are byte-equal, so even an identity-keyed
    /// map collapses them — and both records must still come back.
    func testRecallSurvivesDuplicateCreatedAt() async throws {
        let secrets = InMemorySecretStore()
        let store = try MemoryStore(database: SQLiteDatabase(), secrets: secrets)
        let prefs = MemoryWavePreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!, secrets: secrets)
        let director = WaveDirector(store: store, preferences: prefs, embedder: nil)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await store.insert(
            title: "alpha", body: "shared body text", url: URL(string: "https://example.com/1"),
            kind: .note, containerID: nil, at: stamp)
        _ = try await store.insert(
            title: "alpha", body: "shared body text", url: URL(string: "https://example.com/2"),
            kind: .note, containerID: nil, at: stamp)
        let hits = try await director.recall(containerID: nil, query: "alpha shared body text")
        XCTAssertEqual(hits.count, 2)
    }
}

final class MemoryCipherTests: XCTestCase {
    func testSealOpenRoundTrip() throws {
        let secrets = InMemorySecretStore()
        let key = try MemoryCipher.loadOrCreateKey(in: secrets)
        let box = try MemoryCipher.seal(Data("cognitive".utf8), key: key)
        XCTAssertEqual(try MemoryCipher.open(box, key: key), Data("cognitive".utf8))
    }

    func testTamperedBoxFailsClosed() throws {
        let secrets = InMemorySecretStore()
        let key = try MemoryCipher.loadOrCreateKey(in: secrets)
        var box = try MemoryCipher.seal(Data("secret".utf8), key: key)
        box[box.count - 1] ^= 0xFF
        XCTAssertThrowsError(try MemoryCipher.open(box, key: key))
    }

    /// Sealing an empty plaintext yields exactly 12 (nonce) + 0 (ciphertext)
    /// + 16 (tag) = 28 bytes. `open` used to require `count > 12 + 16`, so a
    /// valid, fully authenticated empty box was rejected as malformed and
    /// every record carrying an empty sealed field became unreadable forever.
    func testSealOpenRoundTripOfEmptyPlaintext() throws {
        let key = try MemoryCipher.loadOrCreateKey(in: InMemorySecretStore())
        let box = try MemoryCipher.seal(Data(), key: key)
        XCTAssertEqual(box.count, 12 + 16, "AES-GCM combined form of an empty plaintext is nonce + tag")
        XCTAssertEqual(try MemoryCipher.open(box, key: key), Data())
    }

    /// Accepting the 28-byte empty box must not soften the length gate: a box
    /// too short to carry a full nonce and tag is still malformed.
    func testBoxShorterThanNonceAndTagIsRejected() throws {
        let key = try MemoryCipher.loadOrCreateKey(in: InMemorySecretStore())
        let box = try MemoryCipher.seal(Data(), key: key)
        for length in [0, 12, 16, 27] {
            XCTAssertThrowsError(try MemoryCipher.open(box.prefix(length), key: key)) { error in
                XCTAssertEqual(error as? MemoryCipherError, .malformedBox, "length \(length) must be malformed")
            }
        }
    }

    /// Nor may it soften authentication: a 28-byte box whose tag was flipped
    /// must fail closed rather than open as "empty".
    func testTamperedEmptyBoxFailsAuthentication() throws {
        let key = try MemoryCipher.loadOrCreateKey(in: InMemorySecretStore())
        var box = try MemoryCipher.seal(Data(), key: key)
        box[box.count - 1] ^= 0xFF
        XCTAssertThrowsError(try MemoryCipher.open(box, key: key)) { error in
            XCTAssertEqual(error as? MemoryCipherError, .authenticationFailed)
        }
    }

    /// A page with a title but no extractable text reaches `remember` with an
    /// empty body (`ArticleExtractor` accepts a title-only extract), so
    /// `body_box` is the 28-byte empty box. The row is written, then dropped
    /// by `decode` on every read -- stored, unreadable, and never reported.
    func testRecordWithEmptyBodySurvivesRoundTrip() async throws {
        let store = try MemoryStore(database: SQLiteDatabase(), secrets: InMemorySecretStore())
        _ = try await store.insert(
            title: "Untitled capture", body: "", url: URL(string: "https://example.com/empty"),
            kind: .browse, containerID: nil)
        let records = try await store.records(containerID: nil)
        XCTAssertEqual(records.map(\.title), ["Untitled capture"])
        XCTAssertEqual(records.first?.body, "")
    }

    func testRecordWithEmptyTitleSurvivesRoundTrip() async throws {
        let store = try MemoryStore(database: SQLiteDatabase(), secrets: InMemorySecretStore())
        _ = try await store.insert(
            title: "", body: "a body with no heading above it", url: nil,
            kind: .note, containerID: nil)
        let records = try await store.records(containerID: nil)
        XCTAssertEqual(records.map(\.body), ["a body with no heading above it"])
        XCTAssertEqual(records.first?.title, "")
    }

    /// decode() authenticates `signature_box` as a fail-closed validity gate
    /// (its plaintext is otherwise unused since the signature is recomputed from
    /// content). A record whose signature_box no longer authenticates must drop.
    func testDecodeDropsRecordWithTamperedSignatureBox() async throws {
        let secrets = InMemorySecretStore()
        let database = try SQLiteDatabase()
        let store = try MemoryStore(database: database, secrets: secrets)
        _ = try await store.insert(
            title: "Work", body: "note", url: nil, kind: .pin, containerID: nil)
        let before = try await store.records(containerID: nil)
        XCTAssertEqual(before.map(\.title), ["Work"])

        // Replace signature_box with a box that no longer authenticates.
        let key = try MemoryCipher.loadOrCreateKey(in: secrets)
        var tampered = try MemoryCipher.seal(Data("x".utf8), key: key)
        tampered[tampered.count - 1] ^= 0xFF
        try await database.run("UPDATE memories SET signature_box = ?1", [.blob(tampered)])

        let after = try await store.records(containerID: nil)
        XCTAssertTrue(after.isEmpty, "record with an unauthenticated signature_box must fail closed")
    }

    /// `MemoryRecord.signature` is derived from `title`/`body` on demand
    /// (see `MemoryRecord.swift`), not recomputed and stored eagerly by
    /// `MemoryStore.decode`. Confirm the on-demand value still matches what
    /// direct construction from the same content produces, so the laziness
    /// is free of behavior change for callers that do read `.signature`.
    func testDecodedRecordSignatureMatchesContentDerivedSignature() async throws {
        let secrets = InMemorySecretStore()
        let store = try MemoryStore(database: SQLiteDatabase(), secrets: secrets)
        _ = try await store.insert(
            title: "Wave", body: "resonance", url: nil, kind: .pin, containerID: nil)
        let records = try await store.records(containerID: nil)
        XCTAssertEqual(records.count, 1)
        let expected = WaveSignature.fromContent(
            Data("Wave\nresonance".utf8),
            identityFrequency: MemoryWaveConstants.consciousness.doubleValue
                * MemoryWaveConstants.goldenRatio.doubleValue
        )
        XCTAssertEqual(records[0].signature.interferenceHash, expected.interferenceHash)
        XCTAssertTrue(records[0].signature.verify())
    }

    /// Issue #86: `decode` used to recompute a `WaveSignature` (a ~1000-step,
    /// 8-harmonic trig reconstruction — ~16,000 trig calls) for every row even
    /// though nothing read the result. `MemoryRecord.signature` is now computed
    /// on demand instead of eagerly in `decode`.
    ///
    /// The bound here is derived, not guessed. The previous version of this
    /// test asserted a flat 5-second wall clock for 256 rows x5, which the
    /// eager path also met comfortably — it read as coverage while gating
    /// nothing. Instead, measure what 256 signature reconstructions cost on
    /// this machine and require one full 256-row read to come in under that.
    ///
    /// Failure then follows from arithmetic rather than from tuning: if
    /// `decode` recomputed a signature per row, its cost would be exactly
    /// those 256 reconstructions *plus* SQLite and four AES-GCM opens per row,
    /// so it could not land below the calibration. Self-calibrating also means
    /// a slow or loaded CI box scales both sides of the comparison together.
    func testDecodingManyRecordsCostsLessThanRecomputingItsSignatures() async throws {
        let secrets = InMemorySecretStore()
        let store = try MemoryStore(database: SQLiteDatabase(), secrets: secrets)
        for index in 0..<256 {
            _ = try await store.insert(
                title: "Title \(index)", body: "Body content for record \(index)",
                url: nil, kind: .note, containerID: nil)
        }

        // Calibration: exactly the work the eager path did, on exactly the
        // content it hashed. The hashes are accumulated so the release-mode
        // optimiser cannot discard the loop as dead code.
        var checksum: UInt64 = 0
        let calibrationStart = Date()
        for index in 0..<256 {
            let signature = WaveSignature.fromContent(
                Data("Title \(index)\nBody content for record \(index)".utf8),
                identityFrequency: MemoryWaveConstants.consciousness.doubleValue
                    * MemoryWaveConstants.goldenRatio.doubleValue
            )
            checksum &+= UInt64(signature.interferenceHash.reduce(0) { UInt64($0) &+ UInt64($1) })
        }
        let eagerSignatureCost = Date().timeIntervalSince(calibrationStart)
        XCTAssertNotEqual(checksum, 0, "calibration loop must actually run")

        let decodeStart = Date()
        let records = try await store.records(containerID: nil, limit: 256)
        let decodeCost = Date().timeIntervalSince(decodeStart)
        XCTAssertEqual(records.count, 256)

        XCTAssertLessThan(
            decodeCost, eagerSignatureCost,
            "reading 256 rows took \(decodeCost)s, no less than the "
                + "\(eagerSignatureCost)s it costs to recompute their signatures — "
                + "decode is computing a WaveSignature per row again (issue #86)")
    }

    /// Regression: a stored key of the wrong length used to fall through to the
    /// generate-and-store path, silently re-keying the store and making every
    /// existing memory undecryptable. The stored bytes must survive untouched —
    /// that is the real guarantee: locked, never destroyed.
    func testMalformedStoredKeyThrowsAndLeavesTheSecretUntouched() throws {
        let secrets = InMemorySecretStore()
        let stored = Data(repeating: 0xAB, count: 16)
        try secrets.setSecret(stored, for: MemoryCipher.keyAccount)

        XCTAssertThrowsError(try MemoryCipher.loadOrCreateKey(in: secrets)) { error in
            XCTAssertEqual(error as? MemoryCipherError, .malformedKey)
        }
        XCTAssertEqual(
            try secrets.secret(for: MemoryCipher.keyAccount), stored,
            "a malformed master key must never be overwritten")
    }

    /// The store must refuse to open rather than come up empty, so callers can
    /// tell "locked" from "nothing remembered yet".
    func testMemoryStoreRefusesToOpenWithMalformedKey() throws {
        let secrets = InMemorySecretStore()
        try secrets.setSecret(Data(repeating: 0x01, count: 31), for: MemoryCipher.keyAccount)
        XCTAssertThrowsError(try MemoryStore(database: SQLiteDatabase(), secrets: secrets)) { error in
            XCTAssertEqual(error as? MemoryCipherError, .malformedKey)
        }
    }

    /// Genuine first run: no secret at all still creates and persists one.
    func testFirstRunCreatesAndReusesKey() throws {
        let secrets = InMemorySecretStore()
        XCTAssertNil(try secrets.secret(for: MemoryCipher.keyAccount))

        let key = try MemoryCipher.loadOrCreateKey(in: secrets)
        let stored = try XCTUnwrap(try secrets.secret(for: MemoryCipher.keyAccount))
        XCTAssertEqual(stored.count, 32)
        XCTAssertEqual(key.withUnsafeBytes { Data($0) }, stored)

        let reloaded = try MemoryCipher.loadOrCreateKey(in: secrets)
        XCTAssertEqual(reloaded.withUnsafeBytes { Data($0) }, stored, "a second load must not re-key")
    }

    /// A valid 32-byte secret still loads, unchanged.
    func testValidStoredKeyLoadsUnchanged() throws {
        let secrets = InMemorySecretStore()
        let stored = Data(repeating: 0x5A, count: 32)
        try secrets.setSecret(stored, for: MemoryCipher.keyAccount)

        let key = try MemoryCipher.loadOrCreateKey(in: secrets)
        XCTAssertEqual(key.withUnsafeBytes { Data($0) }, stored)
        XCTAssertEqual(try secrets.secret(for: MemoryCipher.keyAccount), stored)
    }

    /// The guard above only helps when the *read* sees the truth. This is the
    /// case where it does not: `secret(for:)` reports nothing stored while a
    /// perfectly good key is in fact there. The create branch must fail closed
    /// on the write, not overwrite. Asserted on the bytes, because "threw" and
    /// "did not destroy" are different claims.
    func testCreatePathFailsClosedWhenAReadMissesAnExistingKey() throws {
        let realKey = Data(repeating: 0x7E, count: 32)
        let secrets = BlindReadSecretStore(hidden: [MemoryCipher.keyAccount: realKey])
        XCTAssertNil(
            try secrets.secret(for: MemoryCipher.keyAccount),
            "precondition: the read must miss the item that exists")

        XCTAssertThrowsError(try MemoryCipher.loadOrCreateKey(in: secrets)) { error in
            XCTAssertEqual(error as? SecretStoreError, .duplicateItem)
        }
        XCTAssertEqual(
            secrets.storedBytes(for: MemoryCipher.keyAccount), realKey,
            "an unreadable master key must survive byte-for-byte, never be re-keyed")
    }

    /// Same asymmetry, one level up: the store refuses to come up rather than
    /// coming up on a fresh key over a full database of sealed records.
    func testMemoryStoreFailsClosedWhenAReadMissesAnExistingKey() throws {
        let realKey = Data(repeating: 0x7E, count: 32)
        let secrets = BlindReadSecretStore(hidden: [MemoryCipher.keyAccount: realKey])
        XCTAssertThrowsError(try MemoryStore(database: SQLiteDatabase(), secrets: secrets)) { error in
            XCTAssertEqual(error as? SecretStoreError, .duplicateItem)
        }
        XCTAssertEqual(secrets.storedBytes(for: MemoryCipher.keyAccount), realKey)
    }
}

/// A store whose reads miss an item that actually exists — the shape of a
/// keychain access-group change once the app ships signed, an item living in a
/// different keychain in the search list, or two first-run constructions
/// racing. Reads report nil; the add-only write sees the truth and refuses.
private final class BlindReadSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data]

    init(hidden: [String: Data]) {
        storage = hidden
    }

    func secret(for key: String) throws -> Data? { nil }

    func setSecret(_ data: Data, for key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = data
    }

    func addSecret(_ data: Data, for key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard storage[key] == nil else { throw SecretStoreError.duplicateItem }
        storage[key] = data
    }

    func removeSecret(for key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: key)
    }

    /// What is really stored, bypassing the blind read.
    func storedBytes(for key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }
}

final class MemoryStoreTests: XCTestCase {
    func testContainerIsolationAndEphemeralCallerDuty() async throws {
        let store = try MemoryStore(database: SQLiteDatabase(), secrets: InMemorySecretStore())
        let work = UUID()
        _ = try await store.insert(
            title: "Work", body: "private note", url: URL(string: "https://example.com/a"),
            kind: .pin, containerID: work)
        _ = try await store.insert(
            title: "Personal", body: "other note", url: URL(string: "https://example.com/b"),
            kind: .pin, containerID: nil)

        let workRecords = try await store.records(containerID: work)
        let personalRecords = try await store.records(containerID: nil)
        XCTAssertEqual(workRecords.map(\.title), ["Work"])
        XCTAssertEqual(personalRecords.map(\.title), ["Personal"])
        XCTAssertEqual(workRecords.first?.wave.provenance, .cognitive)
    }

    func testBrowseUpsertAndTimelineGroup() async throws {
        let store = try MemoryStore(database: SQLiteDatabase(), secrets: InMemorySecretStore())
        let url = URL(string: "https://example.com/story")!
        let first = try await store.upsertBrowse(
            title: "One", body: "first", url: url, containerID: nil,
            at: Date(timeIntervalSince1970: 1_700_000_000))
        let second = try await store.upsertBrowse(
            title: "Two", body: "second", url: url, containerID: nil,
            at: Date(timeIntervalSince1970: 1_700_000_100))
        let all = try await store.records(containerID: nil)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].title, "Two")
        XCTAssertEqual(all[0].kind, .browse)
        XCTAssertNotEqual(first.id, second.id)

        let other = try await store.upsertBrowse(
            title: "Other", body: "x", url: URL(string: "https://example.com/b")!, containerID: nil,
            at: Date(timeIntervalSince1970: 1_700_086_400))
        _ = other
        let days = MemoryTimeline.group(try await store.records(since: nil, until: nil, limit: 20))
        XCTAssertGreaterThanOrEqual(days.count, 1)
        let corpusRemote = MemoryTimeline.summaryCorpus(try await store.records(limit: 10), includeSnippets: false)
        XCTAssertFalse(corpusRemote.contains("second"))
        XCTAssertTrue(corpusRemote.contains("Two"))
    }

    func testDeleteContainer() async throws {
        let store = try MemoryStore(database: SQLiteDatabase(), secrets: InMemorySecretStore())
        let id = UUID()
        _ = try await store.insert(title: "Gone", body: "x", url: nil, kind: .note, containerID: id)
        try await store.deleteAll(containerID: id)
        let records = try await store.records(containerID: id)
        XCTAssertTrue(records.isEmpty)
    }

    /// #84: an unopenable row must be logged and counted, not silently
    /// vanish from the result with no trace it was ever there.
    func testUnopenableRowIsCountedNotSilentlyDropped() async throws {
        let database = try SQLiteDatabase()
        let store = try MemoryStore(database: database, secrets: InMemorySecretStore())
        let containerID = UUID()
        _ = try await store.insert(
            title: "Good One", body: "opens fine", url: nil, kind: .note, containerID: containerID)
        let corrupted = try await store.insert(
            title: "Will Be Corrupted", body: "won't survive", url: nil, kind: .note,
            containerID: containerID)
        _ = try await store.insert(
            title: "Good Two", body: "also opens fine", url: nil, kind: .note, containerID: containerID)

        // Simulate a row whose title box was sealed under a different key
        // (Keychain reset, restore-to-new-Mac, etc.) by writing garbage
        // ciphertext directly into the row's title_box.
        try await database.run(
            "UPDATE memories SET title_box = ?1 WHERE id = ?2",
            [.blob(Data(repeating: 0xFF, count: 48)), .integer(corrupted.id)]
        )

        let before = await store.droppedRowCount
        XCTAssertEqual(before, 0)

        let records = try await store.records(containerID: containerID)

        // The two healthy rows still come back...
        XCTAssertEqual(Set(records.map(\.title)), ["Good One", "Good Two"])
        // ...and the corrupted one is neither present...
        XCTAssertFalse(records.contains { $0.id == corrupted.id })
        // ...nor invisible: it was counted...
        let after = await store.droppedRowCount
        XCTAssertEqual(after, 1)

        // A second read against an already-corrupted row keeps accumulating
        // the total rather than resetting it.
        _ = try await store.records(containerID: containerID)
        let afterSecondRead = await store.droppedRowCount
        XCTAssertEqual(afterSecondRead, 2)
    }
}

final class MemoryWavePolicyTests: XCTestCase {
    func testPersistRequiresExplicitAndRejectsEphemeral() {
        let denied = MemoryWavePolicy.decide(
            MemoryWaveContext(
                isExplicit: false, isEphemeral: false, inferenceAllowed: true,
                provider: .none, includeStoredMemory: false, destination: .persist(lane: .odd)))
        XCTAssertEqual(denied, .deny(.notExplicit))

        let ephemeral = MemoryWavePolicy.decide(
            MemoryWaveContext(
                isExplicit: true, isEphemeral: true, inferenceAllowed: true,
                provider: .none, includeStoredMemory: false, destination: .persist(lane: .odd)))
        XCTAssertEqual(ephemeral, .deny(.ephemeral))

        let ok = MemoryWavePolicy.decide(
            MemoryWaveContext(
                isExplicit: true, isEphemeral: false, inferenceAllowed: true,
                provider: .none, includeStoredMemory: false, destination: .persist(lane: .odd)))
        XCTAssertEqual(ok, .allow)
    }

    func testRememberEverythingAllowsLocalPersistButNotEphemeral() {
        let capture = MemoryWavePolicy.decide(
            MemoryWaveContext(
                isExplicit: false, isEphemeral: false, inferenceAllowed: true,
                provider: .none, includeStoredMemory: false, destination: .persist(lane: .odd),
                rememberEverything: true))
        XCTAssertEqual(capture, .allow)

        let ephemeral = MemoryWavePolicy.decide(
            MemoryWaveContext(
                isExplicit: false, isEphemeral: true, inferenceAllowed: true,
                provider: .none, includeStoredMemory: false, destination: .persist(lane: .odd),
                rememberEverything: true))
        XCTAssertEqual(ephemeral, .deny(.ephemeral))
    }

    func testRemoteCannotCarryStoredMemory() {
        let leak = MemoryWavePolicy.decide(
            MemoryWaveContext(
                isExplicit: true, isEphemeral: false, inferenceAllowed: true,
                provider: .openaiCompatible, includeStoredMemory: true,
                destination: .infer, remoteBaseURL: URL(string: "https://api.x.ai/v1")))
        XCTAssertEqual(leak, .deny(.cognitiveEgress))
        XCTAssertFalse(MemoryWavePolicy.remotePayloadAllowed(includeStoredMemory: true))
    }

    func testRemoteRejectsHTTP() {
        let http = MemoryWavePolicy.decide(
            MemoryWaveContext(
                isExplicit: true, isEphemeral: false, inferenceAllowed: true,
                provider: .openaiCompatible, includeStoredMemory: false,
                destination: .infer, remoteBaseURL: URL(string: "http://127.0.0.1:11434")))
        XCTAssertEqual(http, .deny(.insecureEndpoint))
    }

    func testEnergyAndDisabledProvider() {
        XCTAssertEqual(
            MemoryWavePolicy.decide(
                MemoryWaveContext(
                    isExplicit: true, isEphemeral: false, inferenceAllowed: false,
                    provider: .onDevice, includeStoredMemory: false, destination: .infer)),
            .deny(.energy))
        XCTAssertEqual(
            MemoryWavePolicy.decide(
                MemoryWaveContext(
                    isExplicit: true, isEphemeral: false, inferenceAllowed: true,
                    provider: .none, includeStoredMemory: false, destination: .infer)),
            .deny(.providerDisabled))
    }
}

final class ArticleExtractorTests: XCTestCase {
    func testDecodeJSONString() {
        let json = #"{"title":"Hello","text":"World","href":"https://example.com/"}"#
        let extract = ArticleExtractor.decode(json)
        XCTAssertEqual(extract?.title, "Hello")
        XCTAssertEqual(extract?.text, "World")
    }

    func testFallbackStripsTags() {
        let html = "<html><head><title>Doc</title></head><body><script>evil()</script><p>Hi</p></body></html>"
        let extract = ArticleExtractor.fallbackExtract(html: html, url: URL(string: "https://ex.test/"))
        XCTAssertEqual(extract.title, "Doc")
        XCTAssertTrue(extract.text.contains("Hi"))
        XCTAssertFalse(extract.text.contains("evil"))
    }

    func testClamp() {
        let long = ArticleExtract(title: "t", text: String(repeating: "a", count: 50))
        XCTAssertEqual(long.clamped(maxChars: 10).text.count, 10)
    }
}

@MainActor
final class NibbleTests: XCTestCase {
    func testMarkdownRoundTripAndTags() throws {
        let nibble = MemoryNibble(
            title: "Wave grid",
            body: "Sparse 256 grid. #MEM8 lives here.",
            tags: ["WebKit", "#Memory Wave", "webkit"],
            url: URL(string: "https://example.com/mem"),
            kind: .browse,
            containerID: nil
        )
        XCTAssertEqual(nibble.tags, ["webkit", "memory-wave"])
        let key = SymmetricKey(size: .bits256)
        let text = try NibbleMarkdown.encode(nibble, key: key)
        let decoded = NibbleMarkdown.decode(text, key: key)
        XCTAssertEqual(decoded?.title, "Wave grid")
        XCTAssertEqual(decoded?.body, nibble.body)
        XCTAssertEqual(decoded?.tags, nibble.tags)
        XCTAssertEqual(decoded?.url, nibble.url)
        // The tags round-trip (asserted above) but are no longer legible on
        // disk: they are derived from the host and the title, so the plaintext
        // `tags: [...]` line leaked exactly what the sealing is for.
        XCTAssertTrue(text.contains("tags_sealed: "))
        XCTAssertFalse(text.contains("webkit"))
        XCTAssertFalse(text.contains("memory-wave"))
        XCTAssertTrue(text.contains("sealed: aes-gcm-256"))
        // Issue #81: the on-disk file must not contain the plaintext title,
        // body or url that MemoryStore would seal for the same content.
        XCTAssertFalse(text.contains("Wave grid"))
        XCTAssertFalse(text.contains(nibble.body))
        XCTAssertFalse(text.contains("example.com"))
        // A different key must not be able to open it (fail closed, like
        // MemoryStore's AES-GCM authentication).
        XCTAssertNil(NibbleMarkdown.decode(text, key: SymmetricKey(size: .bits256)))
        XCTAssertEqual(NibbleMarkdown.tags(inQuery: "see #webkit and #MEM8"), ["webkit", "mem8"])
    }

    /// A nibble whose title is empty must round-trip. `NibbleCutter` produces
    /// exactly that whenever the captured markdown opens a section with a bare
    /// `#` heading: the section title is the empty string, and a single-chunk
    /// page keeps it verbatim as the nibble title. Sealing "" is a valid
    /// 28-byte box, so the file is written -- and used to be undecodable, which
    /// silently lost the whole nibble, body included.
    func testUntitledNibbleRoundTrips() throws {
        let key = SymmetricKey(size: .bits256)
        let nibble = MemoryNibble(
            title: "",
            body: "Body text that must survive even though the heading was blank.",
            tags: ["qwave"],
            url: URL(string: "https://example.com/untitled"),
            kind: .browse,
            containerID: nil
        )
        let text = try NibbleMarkdown.encode(nibble, key: key)
        let decoded = NibbleMarkdown.decode(text, key: key)
        XCTAssertNotNil(decoded, "an untitled nibble must not become permanently unreadable")
        XCTAssertEqual(decoded?.title, "")
        XCTAssertEqual(decoded?.body, nibble.body)
        XCTAssertEqual(decoded?.url, nibble.url)
    }

    /// The same, end to end from the cutter through the vault: a bare `#`
    /// heading in the page text is the real-world producer of the empty title.
    func testUntitledPageNibbleRoundTripsThroughTheVault() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = try MemoryCipher.loadOrCreateKey(in: InMemorySecretStore())
        let vault = try NibbleVault(directory: dir, key: key)
        let nibbles = NibbleCutter.cut(
            title: "Fallback",
            // "# " with nothing after it: a heading line whose text is empty.
            body: "# \nOnly one section here, and the heading above it carries no text at all.",
            url: URL(string: "https://example.com/untitled"),
            kind: .browse,
            containerID: nil
        )
        XCTAssertEqual(nibbles.count, 1)
        XCTAssertEqual(nibbles.first?.title, "", "a bare heading yields an empty nibble title")
        for nibble in nibbles {
            _ = try await vault.write(nibble)
        }
        let readBack = try await vault.all()
        XCTAssertEqual(readBack.count, 1, "the untitled nibble must be readable back off disk")
        XCTAssertEqual(readBack.first?.body, nibbles.first?.body)
    }

    /// The front matter used to carry the derived tags in the clear, so a
    /// nibble for a medical page left the host and the title words readable on
    /// disk in the very file #107 says holds only ciphertext.
    func testVaultFileDoesNotLeakHostOrTitleWordsThroughTags() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = InMemorySecretStore()
        let key = try MemoryCipher.loadOrCreateKey(in: secrets)
        let vault = try NibbleVault(directory: dir, key: key)
        let store = MemoryStore(database: try SQLiteDatabase(), key: key)
        let prefs = MemoryWavePreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!, secrets: secrets)
        let director = WaveDirector(store: store, preferences: prefs, vault: vault)
        _ = try await director.remember(
            title: "Sekrit Diagnosis Results",
            body: "A paragraph about the appointment that is definitely long enough to keep. #oncology",
            url: URL(string: "https://very-specific-patient-portal.example/records"),
            kind: .pin,
            containerID: nil,
            isEphemeral: false
        )
        let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)!
        let mdFiles = enumerator.allObjects
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "md" && $0.lastPathComponent != "README.md" }
        XCTAssertFalse(mdFiles.isEmpty)
        for file in mdFiles {
            let raw = try String(contentsOf: file, encoding: .utf8)
            for leak in ["patient-portal", "diagnosis", "sekrit", "oncology"] {
                XCTAssertFalse(
                    raw.lowercased().contains(leak),
                    "vault file leaked '\(leak)' through front-matter tags: \(file.lastPathComponent)")
            }
        }
        // Sealing the tags must not cost tag recall: it already decodes every
        // file, so the tags come back decrypted in memory.
        let hits = try await vault.matching(tags: ["oncology"], limit: 8)
        XCTAssertEqual(hits.count, 1)
    }

    /// Nibbles written between #107 and the tag sealing carry `sealed:` plus
    /// plaintext `tags:`. They must keep decoding, tags included.
    func testDecodeReadsPlaintextTagsFromPreTagSealingFiles() throws {
        let key = SymmetricKey(size: .bits256)
        let nibble = MemoryNibble(
            title: "Older nibble", body: "body", tags: ["webkit"], url: nil, kind: .note, containerID: nil)
        let current = try NibbleMarkdown.encode(nibble, key: key)
        // Rebuild the pre-tag-sealing layout: same sealed payloads, tags in the
        // clear, no `tags_sealed:` field.
        var legacy: [String] = []
        for line in current.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("tags_sealed:") {
                legacy.append("tags: [webkit]")
            } else {
                legacy.append(String(line))
            }
        }
        let decoded = NibbleMarkdown.decode(legacy.joined(separator: "\n"), key: key)
        XCTAssertEqual(decoded?.tags, ["webkit"])
        XCTAssertEqual(decoded?.title, "Older nibble")
    }

    func testMarkdownRoundTripThrowsIsAvoidedByHappyPath() throws {
        // encode(_:key:) is throwing (AES-GCM seal can fail); this exercises
        // the non-error path explicitly so a regression that makes it always
        // throw is caught even though `seal` practically never fails.
        let nibble = MemoryNibble(
            title: "t", body: "b", tags: [], url: nil, kind: .note, containerID: nil)
        XCTAssertNoThrow(try NibbleMarkdown.encode(nibble, key: SymmetricKey(size: .bits256)))
    }

    /// A hand-edited vault file can carry a `created:` date before 1970 (e.g.
    /// a backfilled note). Decoding it, and computing the wave for it, must
    /// not trap converting a negative nanosecond count to UInt64 -- issue #85.
    func testDecodePre1970CreatedDateDoesNotTrap() {
        let text = """
            ---
            id: 11111111-1111-1111-1111-111111111111
            kind: nibble
            source: note
            tags: [apollo]
            url:
            created: 1969-07-20T20:17:00Z
            container:
            lane: odd
            ---

            # Tranquility Base

            The Eagle has landed.
            """
        // This is the pre-#81 plaintext format (no `sealed:` field), so the
        // key is unused but still required to call decode.
        let decoded = NibbleMarkdown.decode(text, key: SymmetricKey(size: .bits256))
        XCTAssertEqual(decoded?.title, "Tranquility Base")
        XCTAssertEqual(
            decoded?.created,
            ISO8601DateFormatter().date(from: "1969-07-20T20:17:00Z")
        )
        // The wave is computed eagerly in MemoryNibble.init when no explicit
        // wave is supplied -- this is where the pre-fix trap fired.
        XCTAssertEqual(decoded?.wave.createdAt, 0)
        XCTAssertEqual(decoded?.wave.lastAccessed, 0)
    }

    func testCutterSplitsHeadingsAndKeepsHashtags() {
        let nibbles = NibbleCutter.cut(
            title: "Article",
            body: """
                Intro paragraph that is long enough to keep as its own nibble about browsers.

                ## Marine Algorithm
                Salience is energy plus stability plus harmonic alignment in the watch.

                ## Retrieval
                Tagged nibbles #wave retrieve by resonance instead of a vector scan.
                """,
            url: URL(string: "https://docs.example.com/marine"),
            kind: .browse,
            containerID: nil
        )
        XCTAssertGreaterThanOrEqual(nibbles.count, 2)
        XCTAssertTrue(nibbles.contains(where: { $0.tags.contains("marine") }))
        XCTAssertTrue(nibbles.contains(where: { $0.tags.contains("wave") }))
        XCTAssertTrue(nibbles.contains(where: { $0.tags.contains("docs") }))
    }

    func testVaultWriteAndTagRecall() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = InMemorySecretStore()
        let key = try MemoryCipher.loadOrCreateKey(in: secrets)
        let vault = try NibbleVault(directory: dir, key: key)
        let store = MemoryStore(database: try SQLiteDatabase(), key: key)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let prefs = MemoryWavePreferences(defaults: defaults, secrets: secrets)
        let director = WaveDirector(store: store, preferences: prefs, vault: vault)
        let secretBody = "A paragraph about tagged wave retrieval that is definitely long enough. #qwave"
        _ = try await director.remember(
            title: "Nibble test",
            body: secretBody,
            url: URL(string: "https://qwave.example/nibble"),
            kind: .pin,
            containerID: nil,
            isEphemeral: false
        )
        let hits = try await director.recall(containerID: nil, query: "#qwave", limit: 8)
        XCTAssertFalse(hits.isEmpty)
        XCTAssertTrue(hits.contains(where: { $0.tags.contains("qwave") }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("README.md").path))
        let files = try FileManager.default.subpathsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".md") }
        XCTAssertGreaterThan(files.count, 1)
    }

    /// Regression test for #83: the decode cache used to be keyed on the
    /// vault root's own mtime, which nested `/YYYY/MM/` writes never bump.
    /// An external edit -- a file touched by something other than
    /// `NibbleVault.write(_:)`, e.g. the user in a text editor -- must still
    /// invalidate the cache.
    func testVaultAllPicksUpExternalEditWithoutBumpingRootMtime() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let key = try MemoryCipher.loadOrCreateKey(in: InMemorySecretStore())
        let vault = try NibbleVault(directory: dir, key: key)
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = MemoryNibble(
            title: "Original title",
            body: "Original body about tagged wave retrieval. #qwave",
            tags: ["qwave"],
            url: nil,
            kind: .pin,
            containerID: nil
        )
        let fileURL = try await vault.write(original)

        let rootMtimeBefore = try FileManager.default.attributesOfItem(atPath: dir.path)[.modificationDate] as? Date

        // Populate the decode cache.
        let firstRead = try await vault.all()
        XCTAssertTrue(firstRead.contains(where: { $0.title == "Original title" }))

        // Simulate an external edit: rewrite the file's content directly
        // (bypassing NibbleVault.write) and force its mtime forward, without
        // touching the vault root's mtime at all -- exactly the case #83
        // describes for nested-folder edits.
        let edited = MemoryNibble(
            id: original.id,
            title: "Edited externally",
            body: "Edited body about tagged wave retrieval. #qwave",
            tags: ["qwave"],
            url: nil,
            created: original.created,
            kind: .pin,
            containerID: nil
        )
        try NibbleMarkdown.encode(edited, key: key).write(to: fileURL, atomically: true, encoding: .utf8)
        let future = Date().addingTimeInterval(120)
        try FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: fileURL.path)

        let rootMtimeAfter = try FileManager.default.attributesOfItem(atPath: dir.path)[.modificationDate] as? Date
        XCTAssertEqual(rootMtimeBefore, rootMtimeAfter, "test setup should not itself bump the root mtime")

        let secondRead = try await vault.all()
        XCTAssertTrue(
            secondRead.contains(where: { $0.title == "Edited externally" }),
            "cache should invalidate on an externally edited nibble even though the root mtime is unchanged"
        )
        XCTAssertFalse(secondRead.contains(where: { $0.title == "Original title" }))

        // Simulate an external delete: the vault must stop serving it from
        // cache once the file is gone, not just decline to re-decode it.
        try FileManager.default.removeItem(at: fileURL)
        let thirdRead = try await vault.all()
        XCTAssertFalse(thirdRead.contains(where: { $0.title == "Edited externally" }))
    }

    /// Regression for #82: "Forget all memories" wiped the SQLite store but
    /// left every nibble markdown file on disk. `forgetAll()` must prune the
    /// vault mirror too, not just the store.
    func testForgetAllPrunesTheVaultMirrorToo() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = InMemorySecretStore()
        let key = try MemoryCipher.loadOrCreateKey(in: secrets)
        let vault = try NibbleVault(directory: dir, key: key)
        let store = try MemoryStore(database: SQLiteDatabase(), secrets: secrets)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let prefs = MemoryWavePreferences(defaults: defaults, secrets: secrets)
        let director = WaveDirector(store: store, preferences: prefs, vault: vault)
        _ = try await director.remember(
            title: "Nibble test",
            body: "A paragraph about tagged wave retrieval that is definitely long enough. #qwave",
            url: URL(string: "https://qwave.example/nibble"),
            kind: .pin,
            containerID: nil,
            isEphemeral: false
        )
        let filesBefore = try FileManager.default.subpathsOfDirectory(atPath: dir.path).filter {
            $0.hasSuffix(".md") && $0 != "README.md"
        }
        XCTAssertGreaterThan(filesBefore.count, 0)
        let recordsBefore = try await store.records(containerID: nil, limit: 32)
        XCTAssertFalse(recordsBefore.isEmpty)

        try await director.forgetAll()

        let recordsAfter = try await store.records(containerID: nil, limit: 32)
        XCTAssertTrue(recordsAfter.isEmpty)
        let filesAfter = try FileManager.default.subpathsOfDirectory(atPath: dir.path).filter {
            $0.hasSuffix(".md") && $0 != "README.md"
        }
        XCTAssertTrue(filesAfter.isEmpty, "Expected the vault mirror to be pruned, found: \(filesAfter)")
        // README.md is left in place — the directory itself is not removed.
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("README.md").path))
    }

    /// Issue #81: NibbleVault used to mirror the same body that MemoryStore
    /// AES-seals as plaintext markdown on disk. This asserts none of the
    /// captured page text, title or url reaches the vault files unencrypted
    /// -- the default behavior must not write plaintext bodies.
    func testVaultFilesOnDiskDoNotContainPlaintextBody() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = InMemorySecretStore()
        let key = try MemoryCipher.loadOrCreateKey(in: secrets)
        let vault = try NibbleVault(directory: dir, key: key)
        let store = MemoryStore(database: try SQLiteDatabase(), key: key)
        let prefs = MemoryWavePreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!, secrets: secrets)
        let director = WaveDirector(store: store, preferences: prefs, vault: vault)

        let secretTitle = "Sekrit Diagnosis Results"
        let secretBody = "UnmistakableCanaryPlaintext-\(UUID().uuidString) should never land on disk unsealed."
        let secretHost = "very-specific-patient-portal.example"
        _ = try await director.remember(
            title: secretTitle,
            body: secretBody,
            url: URL(string: "https://\(secretHost)/records"),
            kind: .pin,
            containerID: nil,
            isEphemeral: false
        )

        // `allObjects` rather than iterating the enumerator: this test body is
        // async, and NSEnumerator.makeIterator() is unavailable from async
        // contexts, so the `for case let ... in enumerator` form fails to
        // compile. (NibbleVault.markdownFiles() keeps that form legitimately —
        // it is a synchronous function.)
        let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)!
        let mdFiles = enumerator.allObjects
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "md" && $0.lastPathComponent != "README.md" }
        XCTAssertFalse(mdFiles.isEmpty)
        for file in mdFiles {
            let raw = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(raw.contains(secretTitle), "vault file leaked plaintext title: \(file.lastPathComponent)")
            XCTAssertFalse(raw.contains(secretBody), "vault file leaked plaintext body: \(file.lastPathComponent)")
            XCTAssertFalse(raw.contains(secretHost), "vault file leaked plaintext url: \(file.lastPathComponent)")
            XCTAssertTrue(raw.contains("sealed: aes-gcm-256"))
        }

        // But the sealed content is fully recoverable through the app path:
        // decode-on-read still yields the exact plaintext body in memory.
        let byBody = try await vault.matching(query: "UnmistakableCanaryPlaintext", limit: 8)
        XCTAssertTrue(byBody.contains(where: { $0.body == secretBody }))
    }
}

@MainActor
final class WaveDirectorTests: XCTestCase {
    func testRememberWritesCognitiveWave() async throws {
        let secrets = InMemorySecretStore()
        let store = try MemoryStore(database: SQLiteDatabase(), secrets: secrets)
        let prefs = MemoryWavePreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!, secrets: secrets)
        let director = WaveDirector(store: store, preferences: prefs)
        let record = try await director.remember(
            title: "Page", body: "body", url: URL(string: "https://example.com/"),
            containerID: nil, isEphemeral: false)
        XCTAssertEqual(record.wave.provenance, .cognitive)
        XCTAssertEqual(record.lane, .odd)
    }

    func testRememberDeniedForEphemeral() async throws {
        let secrets = InMemorySecretStore()
        let store = try MemoryStore(database: SQLiteDatabase(), secrets: secrets)
        let prefs = MemoryWavePreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!, secrets: secrets)
        let director = WaveDirector(store: store, preferences: prefs)
        do {
            _ = try await director.remember(
                title: "Nope", body: "x", url: nil, containerID: nil, isEphemeral: true)
            XCTFail("Expected ephemeral memory to be denied")
        } catch {
            XCTAssertEqual(error as? MemoryProviderError, .denied(.ephemeral))
        }
    }

    func testAskRemoteNeverIncludesStoredMemories() async throws {
        let secrets = InMemorySecretStore()
        let store = try MemoryStore(database: SQLiteDatabase(), secrets: secrets)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let prefs = MemoryWavePreferences(defaults: defaults, secrets: secrets)
        prefs.providerKind = .openaiCompatible
        try prefs.setAPIKey("test-key")

        let captured = RequestCapture()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CaptureProtocol.self]
        CaptureProtocol.capture = captured
        CaptureProtocol.responseJSON = """
            {"choices":[{"message":{"role":"assistant","content":"ok"}}]}
            """
        let session = URLSession(configuration: config)

        let director = WaveDirector(store: store, preferences: prefs)
        director.providerOverride = OpenAICompatibleProvider(
            baseURL: MemoryWavePreferences.defaultRemoteBaseURL,
            model: "grok-4.6",
            apiKey: "test-key",
            session: session
        )
        _ = try await director.remember(
            title: "Secret memory", body: "do-not-exfiltrate", url: nil,
            containerID: nil, isEphemeral: false)

        let answer = try await director.ask(
            prompt: "What do you know?",
            page: ArticleExtract(title: "Now", text: "visible page"),
            containerID: nil,
            isEphemeral: false,
            inferenceAllowed: true
        )
        XCTAssertEqual(answer.text, "ok")
        XCTAssertFalse(answer.usedStoredMemory)
        let sent = String(data: captured.body ?? Data(), encoding: .utf8) ?? ""
        XCTAssertFalse(sent.contains("do-not-exfiltrate"))
        XCTAssertFalse(sent.contains("Secret memory"))
        XCTAssertTrue(sent.contains("visible page"))
    }

    /// `resolveProvider()` is the only place the shipping app builds a remote
    /// provider, so it is the only place the bounded session can be lost.
    /// Passing `session: .shared` there would restore the seven-day ceiling
    /// with every other test still green — this test is what fails.
    func testResolveProviderBuildsBoundedRemoteProvider() throws {
        let secrets = InMemorySecretStore()
        let prefs = MemoryWavePreferences(
            defaults: UserDefaults(suiteName: UUID().uuidString)!, secrets: secrets)
        prefs.providerKind = .openaiCompatible
        prefs.remoteModel = "grok-4.6"
        try prefs.setAPIKey("test-key")
        let director = WaveDirector(store: nil, preferences: prefs, embedder: nil)

        let provider = try XCTUnwrap(director.resolveProvider() as? OpenAICompatibleProvider)
        XCTAssertEqual(provider.baseURL, prefs.remoteBaseURL)
        XCTAssertEqual(provider.model, "grok-4.6")
        XCTAssertEqual(provider.apiKey, "test-key")
        XCTAssertTrue(provider.isAvailable)

        XCTAssertFalse(
            provider.session === URLSession.shared,
            "the production path must not fall back to URLSession.shared (7-day resource ceiling)")
        let configuration = provider.session.configuration
        XCTAssertEqual(provider.timeout, OpenAICompatibleProvider.defaultTimeout)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, OpenAICompatibleProvider.defaultTimeout)
        XCTAssertEqual(
            configuration.timeoutIntervalForResource, OpenAICompatibleProvider.defaultResourceTimeout)
        XCTAssertLessThan(configuration.timeoutIntervalForResource, 600)
    }

    /// The privacy default: nothing configured means no provider and no egress.
    func testResolveProviderStaysOfflineByDefault() throws {
        let prefs = MemoryWavePreferences(
            defaults: UserDefaults(suiteName: UUID().uuidString)!, secrets: InMemorySecretStore())
        XCTAssertEqual(prefs.providerKind, .none)
        let director = WaveDirector(store: nil, preferences: prefs, embedder: nil)

        let provider = try director.resolveProvider()
        XCTAssertTrue(provider is NullMemoryProvider)
        XCTAssertEqual(provider.kind, .none)
        XCTAssertFalse(provider.isAvailable)
    }
}

/// The remote provider is the one deliberate step outside `EgressAllowlist`
/// (the base URL is user-configurable). It must therefore carry an explicit
/// deadline: a hung endpoint must not hold the summarize flow open.
final class RemoteProviderTimeoutTests: XCTestCase {
    func testDefaultSessionCarriesBothDeadlines() {
        let provider = OpenAICompatibleProvider(
            baseURL: MemoryWavePreferences.defaultRemoteBaseURL,
            model: "grok-4.6",
            apiKey: "test-key"
        )
        let configuration = provider.session.configuration
        XCTAssertEqual(provider.timeout, OpenAICompatibleProvider.defaultTimeout)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, OpenAICompatibleProvider.defaultTimeout)
        XCTAssertEqual(configuration.timeoutIntervalForResource, OpenAICompatibleProvider.defaultResourceTimeout)
        // URLSession.shared's resource ceiling is seven days; ours is a minute.
        XCTAssertLessThan(configuration.timeoutIntervalForResource, 600)
    }

    func testOutgoingRequestCarriesTimeout() async throws {
        let captured = RequestCapture()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CaptureProtocol.self]
        CaptureProtocol.capture = captured
        CaptureProtocol.responseJSON = """
            {"choices":[{"message":{"role":"assistant","content":"ok"}}]}
            """

        let provider = OpenAICompatibleProvider(
            baseURL: MemoryWavePreferences.defaultRemoteBaseURL,
            model: "grok-4.6",
            apiKey: "test-key",
            timeout: 7,
            session: URLSession(configuration: config)
        )
        let text = try await provider.complete(system: "system", user: "user")
        XCTAssertEqual(text, "ok")
        XCTAssertEqual(captured.timeout, 7)
    }

    func testHungEndpointFailsInsteadOfHanging() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HangingProtocol.self]

        let provider = OpenAICompatibleProvider(
            baseURL: MemoryWavePreferences.defaultRemoteBaseURL,
            model: "grok-4.6",
            apiKey: "test-key",
            timeout: 1,
            session: URLSession(configuration: config)
        )
        do {
            _ = try await provider.complete(system: "system", user: "user")
            XCTFail("Expected the hung endpoint to time out")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
    }

    /// The idle timer above cannot catch an endpoint that keeps trickling
    /// bytes — every byte rearms it. Only `timeoutIntervalForResource` ends
    /// that exchange, so drive it directly: a stub that answers 200 and then
    /// dribbles a byte every 200ms forever, against a request timeout far
    /// larger than the resource ceiling. Nothing but the ceiling can fail this:
    /// with the ceiling removed this test runs 50s and fails, with it, 2s.
    /// The ceiling is compressed to 2s here so CI stays fast; that the shipping
    /// value is 60s and reaches the production provider is pinned separately by
    /// `testDefaultSessionCarriesBothDeadlines` and by
    /// `testResolveProviderBuildsBoundedRemoteProvider`.
    func testDribblingEndpointIsCutOffByTheResourceCeiling() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DribblingProtocol.self]
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 2

        let provider = OpenAICompatibleProvider(
            baseURL: MemoryWavePreferences.defaultRemoteBaseURL,
            model: "grok-4.6",
            apiKey: "test-key",
            timeout: 30,
            session: URLSession(configuration: config)
        )
        let started = Date()
        do {
            _ = try await provider.complete(system: "system", user: "user")
            XCTFail("Expected the dribbling endpoint to hit the resource ceiling")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        // Bounded by the resource ceiling, not by the 30s idle timer.
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
    }
}

/// Settings promises the page text goes "to this endpoint". A 307 replays the
/// POST — method and body intact — wherever the response points, so that
/// promise only holds if redirects are bounded.
final class RemoteProviderRedirectTests: XCTestCase {
    override func tearDown() {
        RedirectProtocol.secondHop = nil
        super.tearDown()
    }

    func testCrossHostRedirectNeverReceivesThePageText() async throws {
        let secondHop = RequestCapture()
        RedirectProtocol.secondHop = secondHop
        RedirectProtocol.target = URL(string: "https://collector.example/v1/chat/completions")!
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RedirectProtocol.self]

        let provider = OpenAICompatibleProvider(
            baseURL: MemoryWavePreferences.defaultRemoteBaseURL,
            model: "grok-4.6",
            apiKey: "test-key",
            timeout: 2,
            session: URLSession(configuration: config)
        )
        do {
            let text = try await provider.complete(system: "system", user: "PAGE-CONTENT-HERE")
            XCTFail("Expected the off-endpoint redirect to be refused, got \(text)")
        } catch {
            // Deliberately not pinned to a specific error. Against a live server
            // a refused redirect ends the task with the 3xx itself, so `complete`
            // throws .transport("HTTP 307"). A `URLProtocol` stub has no way to
            // model that: once the delegate declines, the stub's load is simply
            // never finished, so the task ends at the request timeout instead.
            // The claim under test is where the bytes went, not which error came
            // back — so assert that, and keep the timeout short so a regression
            // (redirect followed, second hop answers) fails fast either way.
        }
        XCTAssertNil(secondHop.url, "the second host must never be contacted")
        XCTAssertNil(secondHop.body, "the page text must never reach the second host")
    }

    /// A redirect that stays on the configured origin keeps the promise, so it
    /// is still followed — self-hosted proxies move paths around.
    func testSameOriginRedirectIsFollowed() async throws {
        let secondHop = RequestCapture()
        RedirectProtocol.secondHop = secondHop
        RedirectProtocol.target = MemoryWavePreferences.defaultRemoteBaseURL
            .appendingPathComponent("v2/chat/completions")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RedirectProtocol.self]

        let provider = OpenAICompatibleProvider(
            baseURL: MemoryWavePreferences.defaultRemoteBaseURL,
            model: "grok-4.6",
            apiKey: "test-key",
            session: URLSession(configuration: config)
        )
        let text = try await provider.complete(system: "system", user: "PAGE-CONTENT-HERE")
        XCTAssertEqual(text, "second-hop")
        XCTAssertEqual(secondHop.url?.host, MemoryWavePreferences.defaultRemoteBaseURL.host)
    }

    func testPolicyBoundsTheOriginPrecisely() {
        let endpoint = URL(string: "https://api.x.ai/v1/chat/completions")!
        let allows = { (candidate: String) in
            EndpointRedirectPolicy.staysOnEndpoint(URL(string: candidate)!, endpoint: endpoint)
        }
        XCTAssertTrue(allows("https://api.x.ai/v2/chat/completions"))
        XCTAssertTrue(allows("https://API.X.AI/v1/chat/completions"))
        XCTAssertTrue(allows("https://api.x.ai:443/v1/chat/completions"))
        // Off-origin, downgraded, or re-pointed at another port: refused.
        XCTAssertFalse(allows("https://collector.example/v1/chat/completions"))
        XCTAssertFalse(allows("https://api.x.ai.evil.net/v1/chat/completions"))
        XCTAssertFalse(allows("https://evil.api.x.ai/v1/chat/completions"))
        XCTAssertFalse(allows("http://api.x.ai/v1/chat/completions"))
        XCTAssertFalse(allows("https://api.x.ai:8443/v1/chat/completions"))
    }
}

private final class RequestCapture: @unchecked Sendable {
    var body: Data?
    var timeout: TimeInterval?
    var url: URL?
}

/// Answers the first hop with a 307 to `target`, replaying method and body the
/// way a live 307 does. If the redirect is followed, the second hop records
/// exactly what arrived there.
private final class RedirectProtocol: URLProtocol {
    nonisolated(unsafe) static var target = URL(string: "https://collector.example/v1/chat/completions")!
    nonisolated(unsafe) static var secondHop: RequestCapture?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        if url == Self.target {
            Self.secondHop?.url = url
            Self.secondHop?.body = request.httpBody ?? bodyFromStream(request)
            let data = Data(#"{"choices":[{"message":{"role":"assistant","content":"second-hop"}}]}"#.utf8)
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        var replay = request
        replay.url = Self.target
        let redirect = HTTPURLResponse(
            url: url, statusCode: 307, httpVersion: "HTTP/1.1",
            headerFields: ["Location": Self.target.absoluteString])!
        client?.urlProtocol(self, wasRedirectedTo: replay, redirectResponse: redirect)
    }

    override func stopLoading() {}

    private func bodyFromStream(_ request: URLRequest) -> Data? {
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
        defer { buf.deallocate() }
        while stream.hasBytesAvailable {
            let n = stream.read(buf, maxLength: 1024)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data
    }
}

/// Answers, then never finishes: one byte at a time, forever. Every byte
/// rearms the idle timer, so only the resource ceiling can end this.
private final class DribblingProtocol: URLProtocol {
    private let lock = NSLock()
    private var isStopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        nonisolated(unsafe) let unsafeSelf = self
        DispatchQueue(label: "qwave.test.dribble").async {
            // Capped so a bug in the ceiling ends as a test failure, not a hang.
            for _ in 0..<100 {
                guard !unsafeSelf.stopped() else { return }
                unsafeSelf.client?.urlProtocol(unsafeSelf, didLoad: Data(" ".utf8))
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
    }

    override func stopLoading() {
        lock.withLock { isStopped = true }
    }

    private func stopped() -> Bool {
        lock.withLock { isStopped }
    }
}

/// Accepts the connection and then never answers, standing in for an endpoint
/// that hangs.
private final class HangingProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

private final class CaptureProtocol: URLProtocol {
    nonisolated(unsafe) static var capture: RequestCapture?
    nonisolated(unsafe) static var responseJSON = ""

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capture?.body = request.httpBody ?? httpBodyFromStream(request)
        Self.capture?.timeout = request.timeoutInterval
        let data = Data(Self.responseJSON.utf8)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func httpBodyFromStream(_ request: URLRequest) -> Data? {
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
        defer { buf.deallocate() }
        while stream.hasBytesAvailable {
            let n = stream.read(buf, maxLength: 1024)
            if n > 0 { data.append(buf, count: n) } else { break }
        }
        return data
    }
}
