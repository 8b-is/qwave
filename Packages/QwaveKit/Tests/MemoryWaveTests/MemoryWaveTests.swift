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
    func testMarkdownRoundTripAndTags() {
        let nibble = MemoryNibble(
            title: "Wave grid",
            body: "Sparse 256 grid. #MEM8 lives here.",
            tags: ["WebKit", "#Memory Wave", "webkit"],
            url: URL(string: "https://example.com/mem"),
            kind: .browse,
            containerID: nil
        )
        XCTAssertEqual(nibble.tags, ["webkit", "memory-wave"])
        let text = NibbleMarkdown.encode(nibble)
        let decoded = NibbleMarkdown.decode(text)
        XCTAssertEqual(decoded?.title, "Wave grid")
        XCTAssertEqual(decoded?.tags, nibble.tags)
        XCTAssertEqual(decoded?.url, nibble.url)
        XCTAssertTrue(text.contains("tags: [webkit, memory-wave]"))
        XCTAssertEqual(NibbleMarkdown.tags(inQuery: "see #webkit and #MEM8"), ["webkit", "mem8"])
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
        let vault = try NibbleVault(directory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = InMemorySecretStore()
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
        let hits = try await director.recall(containerID: nil, query: "#qwave", limit: 8)
        XCTAssertFalse(hits.isEmpty)
        XCTAssertTrue(hits.contains(where: { $0.tags.contains("qwave") }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("README.md").path))
        let files = try FileManager.default.subpathsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".md") }
        XCTAssertGreaterThan(files.count, 1)
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
}

private final class RequestCapture: @unchecked Sendable {
    var body: Data?
}

private final class CaptureProtocol: URLProtocol {
    nonisolated(unsafe) static var capture: RequestCapture?
    nonisolated(unsafe) static var responseJSON = ""

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capture?.body = request.httpBody ?? httpBodyFromStream(request)
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
