import CryptoKit
import XCTest
@testable import MemoryWave
import QwaveSupport

/// Issue #120: nibble files written by a release older than #107 are still
/// plaintext on disk, and nothing re-seals them. These cover the migration that
/// does, with the emphasis on the failure that would be worse than the bug --
/// losing a memory instead of leaving it readable.
final class NibbleVaultResealTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    /// The exact shape a pre-#107 release wrote: no `sealed:` marker, a `# `
    /// heading, the body as page text, `url:` and `tags:` in the clear.
    private func writeLegacyPlaintext(named name: String = "2024-03-01-oncology-abcdef12.md") throws -> URL {
        let folder = directory.appendingPathComponent("2024/03", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try """
            ---
            id: 5a2e9c1e-0000-4000-8000-1234567890ab
            kind: nibble
            source: browse
            tags: [oncology, patient-portal]
            url: https://very-specific-patient-portal.example/records
            created: 2024-03-01T10:00:00Z
            container:
            lane: odd
            ---

            # Sekrit Diagnosis Results

            A paragraph about the appointment that is long enough to keep.

            """.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The in-between generation: #107 sealed title/body/url but still wrote
    /// the derived tags -- host plus title words -- as cleartext `tags:`.
    private func writePreTagSealing(key: SymmetricKey) throws -> URL {
        let nibble = MemoryNibble(
            title: "Interim nibble",
            body: "Body sealed by #107 but with its tags still legible on disk.",
            tags: ["oncology", "patient-portal"],
            url: URL(string: "https://very-specific-patient-portal.example/interim"),
            created: Date(timeIntervalSince1970: 1_710_000_000),
            kind: .browse,
            containerID: nil
        )
        let current = try NibbleMarkdown.encode(nibble, key: key)
        let downgraded = current.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                line.hasPrefix("tags_sealed:") ? "tags: [oncology, patient-portal]" : String(line)
            }
            .joined(separator: "\n")
        let folder = directory.appendingPathComponent("2024/03", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("2024-03-09-interim-11112222.md")
        try downgraded.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func nibbleFiles() throws -> [URL] {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)!
        return enumerator.allObjects
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "md" && $0.lastPathComponent != "README.md" }
            .sorted { $0.path < $1.path }
    }

    // MARK: - Tests

    /// The headline case: a pre-#107 file is sealed in place, and the memory it
    /// held reads back byte-identical afterwards.
    func testLegacyPlaintextFileIsResealedWithIdenticalContent() async throws {
        let secrets = InMemorySecretStore()
        let key = try MemoryCipher.loadOrCreateKey(in: secrets)
        let file = try writeLegacyPlaintext()
        let before = try XCTUnwrap(NibbleMarkdown.decode(String(contentsOf: file, encoding: .utf8), key: key))

        let summary = await NibbleVault.resealLegacyNibbles(directory: directory, secrets: secrets)
        XCTAssertEqual(summary.resealed, 1)
        XCTAssertEqual(summary.unreadable, 0)
        XCTAssertEqual(summary.failed, 0)
        XCTAssertFalse(summary.keyLocked)

        let raw = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(raw.contains("sealed: aes-gcm-256"), "the file must carry the sealing marker after migration")
        XCTAssertTrue(raw.contains("tags_sealed: "))
        for leak in ["Sekrit", "Diagnosis", "oncology", "patient-portal", "appointment"] {
            XCTAssertFalse(
                raw.lowercased().contains(leak.lowercased()),
                "re-sealed file still leaks '\(leak)' in cleartext")
        }

        let after = try XCTUnwrap(NibbleMarkdown.decode(raw, key: key))
        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(after.title, before.title)
        XCTAssertEqual(after.body, before.body)
        XCTAssertEqual(after.tags, before.tags)
        XCTAssertEqual(after.url, before.url)
        XCTAssertEqual(after.created, before.created)
        XCTAssertEqual(after.kind, before.kind)
        XCTAssertEqual(after.lane, before.lane)
        XCTAssertEqual(after.containerID, before.containerID)
        // And it is reachable through the ordinary read path, not just the
        // decoder: a migration that seals a file out of recall is a data loss.
        let vault = try NibbleVault(directory: directory, key: key)
        let recalled = try await vault.matching(tags: ["oncology"], limit: 8)
        XCTAssertEqual(recalled.count, 1)
        XCTAssertEqual(recalled.first?.body, before.body)
    }

    /// The #107-to-tag-sealing generation loses its cleartext `tags:` line too.
    func testPreTagSealingFileIsUpgraded() async throws {
        let secrets = InMemorySecretStore()
        let key = try MemoryCipher.loadOrCreateKey(in: secrets)
        let file = try writePreTagSealing(key: key)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("tags: [oncology"))

        let summary = await NibbleVault.resealLegacyNibbles(directory: directory, secrets: secrets)
        XCTAssertEqual(summary.resealed, 1)

        let raw = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(raw.contains("oncology"))
        XCTAssertFalse(raw.contains("patient-portal"))
        XCTAssertTrue(raw.contains("tags_sealed: "))
        let decoded = try XCTUnwrap(NibbleMarkdown.decode(raw, key: key))
        XCTAssertEqual(decoded.tags, ["oncology", "patient-portal"])
        XCTAssertEqual(decoded.body, "Body sealed by #107 but with its tags still legible on disk.")
    }

    /// Running the pass twice must change nothing the second time -- same
    /// bytes, same mtimes. Anything else means the vault churns on every launch.
    func testSecondRunIsANoOp() async throws {
        let secrets = InMemorySecretStore()
        _ = try MemoryCipher.loadOrCreateKey(in: secrets)
        _ = try writeLegacyPlaintext()

        let first = await NibbleVault.resealLegacyNibbles(directory: directory, secrets: secrets)
        XCTAssertEqual(first.resealed, 1)

        var contents: [URL: Data] = [:]
        var mtimes: [URL: Date] = [:]
        for file in try nibbleFiles() {
            contents[file] = try Data(contentsOf: file)
            mtimes[file] = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        }

        let second = await NibbleVault.resealLegacyNibbles(directory: directory, secrets: secrets)
        XCTAssertEqual(second.resealed, 0, "a second pass must not rewrite anything")
        XCTAssertEqual(second.alreadySealed, 1)
        XCTAssertEqual(second.failed, 0)

        XCTAssertEqual(Set(try nibbleFiles()), Set(contents.keys))
        for file in try nibbleFiles() {
            XCTAssertEqual(try Data(contentsOf: file), contents[file], "file rewritten on the second pass")
            let mtime = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
            XCTAssertEqual(mtime, mtimes[file], "file touched on the second pass")
        }
    }

    /// A locked master key must stop the pass dead. Re-sealing under a key that
    /// is not the user's would turn a readable memory into an unopenable one --
    /// strictly worse than the plaintext this migration exists to remove.
    func testLockedKeyMakesTheMigrationANoOp() async throws {
        let secrets = InMemorySecretStore()
        // A stored-but-malformed key: exactly what `loadOrCreateKey` refuses to
        // overwrite, and what leaves `BrowserEnvironment` with a nil vault.
        try secrets.addSecret(Data([1, 2, 3]), for: MemoryCipher.keyAccount)
        let file = try writeLegacyPlaintext()
        let original = try Data(contentsOf: file)

        let summary = await NibbleVault.resealLegacyNibbles(directory: directory, secrets: secrets)
        XCTAssertTrue(summary.keyLocked)
        XCTAssertEqual(summary.scanned, 0)
        XCTAssertEqual(summary.resealed, 0)

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "a file we could not re-seal was removed")
        XCTAssertEqual(try Data(contentsOf: file), original)
        // Still readable: the plaintext format needs no key at all, so the user
        // has not lost the memory while the keychain is broken.
        let decoded = try XCTUnwrap(
            NibbleMarkdown.decode(String(contentsOf: file, encoding: .utf8), key: SymmetricKey(size: .bits256)))
        XCTAssertEqual(decoded.title, "Sekrit Diagnosis Results")
    }

    /// With no key stored at all the pass also does nothing, rather than
    /// minting one: a keychain that reads back empty for any reason other than
    /// a genuine first run would otherwise get every nibble sealed under a key
    /// the rest of the user's memories do not use.
    func testMissingKeyMakesTheMigrationANoOp() async throws {
        let file = try writeLegacyPlaintext()
        let original = try Data(contentsOf: file)
        let summary = await NibbleVault.resealLegacyNibbles(directory: directory, secrets: InMemorySecretStore())
        XCTAssertTrue(summary.keyLocked)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    /// Crash between "temp written" and "rename": the original is still there,
    /// the temp is debris. The vault must be consistent, and the next run must
    /// finish the job.
    func testInterruptedResealLeavesTheVaultConsistentAndResumes() async throws {
        let secrets = InMemorySecretStore()
        let key = try MemoryCipher.loadOrCreateKey(in: secrets)
        let file = try writeLegacyPlaintext()
        let stranded = file.appendingPathExtension(NibbleVault.resealTempSuffix)
        try "half-written debris from a killed pass".write(to: stranded, atomically: true, encoding: .utf8)

        // Before the re-run: the memory is intact, and the debris is invisible
        // to every read path -- it is not a `.md` file.
        let vault = try NibbleVault(directory: directory, key: key)
        let beforeRerun = try await vault.all()
        XCTAssertEqual(beforeRerun.count, 1)

        let summary = await NibbleVault.resealLegacyNibbles(directory: directory, secrets: secrets)
        XCTAssertEqual(summary.resealed, 1)
        XCTAssertEqual(summary.scanned, 1, "the temp file must not be scanned as a nibble")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stranded.path),
            "the interrupted pass's temp file must be swept")
        let raw = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(raw.contains("sealed: aes-gcm-256"))
        XCTAssertEqual(NibbleMarkdown.decode(raw, key: key)?.title, "Sekrit Diagnosis Results")
        XCTAssertEqual(try nibbleFiles().count, 1, "no duplicate or orphaned nibble left behind")
    }

    /// A vault the user has been adding to since the update: old plaintext next
    /// to new sealed files. Only the old ones may move.
    func testMixedVaultOnlyRewritesTheLegacyFiles() async throws {
        let secrets = InMemorySecretStore()
        let key = try MemoryCipher.loadOrCreateKey(in: secrets)
        let vault = try NibbleVault(directory: directory, key: key)
        let fresh = try await vault.write(
            MemoryNibble(
                title: "Written after the fix",
                body: "A current-format nibble that the migration must not touch.",
                tags: ["qwave"],
                url: URL(string: "https://qwave.example/fresh"),
                kind: .pin,
                containerID: nil
            )
        )
        let freshBytes = try Data(contentsOf: fresh)
        let freshMtime = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: fresh.path)[.modificationDate] as? Date)
        let legacy = try writeLegacyPlaintext()
        let legacyBytes = try Data(contentsOf: legacy)

        let summary = await NibbleVault.resealLegacyNibbles(directory: directory, secrets: secrets)
        XCTAssertEqual(summary.scanned, 2)
        XCTAssertEqual(summary.resealed, 1)
        XCTAssertEqual(summary.alreadySealed, 1)

        XCTAssertEqual(try Data(contentsOf: fresh), freshBytes, "an already-sealed file was rewritten")
        XCTAssertEqual(
            try XCTUnwrap(FileManager.default.attributesOfItem(atPath: fresh.path)[.modificationDate] as? Date),
            freshMtime)
        XCTAssertNotEqual(try Data(contentsOf: legacy), legacyBytes)
        // Both memories survive, through the ordinary read path.
        let all = try await NibbleVault(directory: directory, key: key).all()
        XCTAssertEqual(Set(all.map(\.title)), ["Written after the fix", "Sekrit Diagnosis Results"])
    }

    /// A file sealed under a *different* key is not ours to rewrite. It must be
    /// counted and left alone, never deleted and never re-sealed from a decode
    /// that did not happen.
    func testFileSealedUnderAnotherKeyIsLeftUntouched() async throws {
        let secrets = InMemorySecretStore()
        _ = try MemoryCipher.loadOrCreateKey(in: secrets)
        // Sealed by the current encoder, so it does not "need" re-sealing --
        // and a plaintext one whose front matter we cannot decode either.
        let folder = directory.appendingPathComponent("2024/04", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let foreign = folder.appendingPathComponent("2024-04-01-foreign-99998888.md")
        let foreignKey = SymmetricKey(size: .bits256)
        let text = try NibbleMarkdown.encode(
            MemoryNibble(title: "Other key", body: "b", tags: ["x"], url: nil, kind: .note, containerID: nil),
            key: foreignKey)
        // Strip `tags_sealed` so the pass considers it in need of upgrading and
        // then discovers it cannot open it.
        let downgraded = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("tags_sealed:") ? "tags: [x]" : String($0) }
            .joined(separator: "\n")
        try downgraded.write(to: foreign, atomically: true, encoding: .utf8)
        let bytes = try Data(contentsOf: foreign)

        let summary = await NibbleVault.resealLegacyNibbles(directory: directory, secrets: secrets)
        XCTAssertEqual(summary.unreadable, 1)
        XCTAssertEqual(summary.resealed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
        XCTAssertEqual(try Data(contentsOf: foreign), bytes, "an undecodable file must be left byte-identical")
    }

    /// `needsReseal` decides what the pass touches, so it has to agree with the
    /// decoder about every generation of the format -- and refuse anything that
    /// is not a nibble at all.
    func testNeedsResealRecognisesEachGeneration() throws {
        let key = SymmetricKey(size: .bits256)
        let nibble = MemoryNibble(
            title: "t", body: "b", tags: [], url: nil, kind: .note, containerID: nil)
        XCTAssertFalse(try NibbleMarkdown.needsReseal(NibbleMarkdown.encode(nibble, key: key)))
        XCTAssertTrue(NibbleMarkdown.needsReseal("---\nid: x\nlane: odd\n---\n\n# Title\n\nbody\n"))
        XCTAssertTrue(
            NibbleMarkdown.needsReseal("---\nid: x\nsealed: aes-gcm-256\ntags: [a]\n---\n\nbody\n"),
            "a sealed file with cleartext tags still needs upgrading")
        XCTAssertTrue(
            NibbleMarkdown.needsReseal("---\nid: x\nsealed: aes-gcm-256\ntags_sealed:\n---\n\nbody\n"),
            "an empty tags_sealed is not something this encoder ever writes")
        XCTAssertFalse(NibbleMarkdown.needsReseal("# Just a markdown file\n"))
        XCTAssertFalse(NibbleMarkdown.needsReseal(""))
    }
}
