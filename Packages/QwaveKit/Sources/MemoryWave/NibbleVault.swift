import CryptoKit
import Foundation
import QwaveSupport

/// Outcome of one `NibbleVault.resealLegacyNibbles()` pass. Counts only --
/// nothing here identifies a file, let alone its content.
public struct NibbleResealSummary: Equatable, Sendable {
    /// Nibble files the pass looked at.
    public var scanned = 0
    /// Files rewritten from a pre-#107 (or pre-tag-sealing) form to the current
    /// sealed one.
    public var resealed = 0
    /// Files already in the current form, left byte-for-byte untouched.
    public var alreadySealed = 0
    /// Files that could not be read or could not be decoded with this key.
    /// Left exactly as found -- a migration never deletes what it cannot read.
    public var unreadable = 0
    /// Files whose sealed replacement could not be written or failed its
    /// read-back check. The original is intact and still the file on disk.
    public var failed = 0
    /// The master key could not be loaded, so the pass did nothing at all.
    /// Distinct from an empty vault: plaintext files may well be present.
    public var keyLocked = false

    public init(
        scanned: Int = 0, resealed: Int = 0, alreadySealed: Int = 0,
        unreadable: Int = 0, failed: Int = 0, keyLocked: Bool = false
    ) {
        self.scanned = scanned
        self.resealed = resealed
        self.alreadySealed = alreadySealed
        self.unreadable = unreadable
        self.failed = failed
        self.keyLocked = keyLocked
    }
}

/// Tag-indexed, local-only vault of nibbles, stored as `.md` files whose
/// tags/title/body/url are AES-GCM sealed with the same Memory Wave master key
/// that seals `MemoryStore` (issue #81). Only content-free bookkeeping -- kind,
/// lane, timestamps, ids -- stays in the clear, for file naming and ordering.
/// The tags are sealed with the rest because they are derived from the content
/// (host + title words), and tag search never needed them in the clear anyway:
/// `matching(tags:)` goes through `all(limit:)`, which decodes every file.
/// The vault used to mirror the sealed database body as plaintext
/// markdown; a file opened outside Qwave now shows ciphertext, matching the
/// at-rest guarantee the primary store already made. Human-readable export
/// of a nibble remains a decrypt-on-demand operation inside the app.
///
/// An actor so the enumeration + file reads in `all(limit:)` run off the main
/// thread when awaited from `@MainActor` callers, and so the decode cache is
/// mutated under serialized isolation.
public actor NibbleVault {
    public nonisolated let directory: URL
    private let key: SymmetricKey

    /// Decoded nibbles memoized per source file's modification time.
    /// Repeated recalls with an unchanged vault reuse this instead of
    /// re-reading and re-decoding every file. The vault root's own mtime is
    /// *not* a reliable signal here: nibbles live in nested `/YYYY/MM/`
    /// folders, and on APFS an add/edit/delete inside a leaf folder bumps
    /// that folder's mtime, not the root's -- and edits made outside this
    /// process (Finder, another app, git) are exactly the case that matters,
    /// since `write(_:)` can invalidate its own writes but not those. Instead
    /// each `all(limit:)` call re-enumerates the (cheap, stat-only) file list
    /// and compares per-file mtimes, only re-reading and re-decoding files
    /// that are new or whose mtime changed since the last cache fill.
    private var cache: (mtimes: [URL: Date], nibbles: [URL: MemoryNibble])?
    private static let cacheLimit = 400

    /// - Parameter key: the Memory Wave master key (`MemoryCipher.loadOrCreateKey`).
    ///   Callers should derive this the same way `MemoryStore` does and pass
    ///   the *same* key, so the vault and the sealed database lock and unlock
    ///   together instead of drifting into independent threat models.
    public init(directory: URL, key: SymmetricKey) throws {
        self.directory = directory
        self.key = key
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let readme = directory.appendingPathComponent("README.md")
        if !FileManager.default.fileExists(atPath: readme.path) {
            try """
            # Memory Wave nibbles

            Each file is a tagged Cognitive nibble. Wave recall matches `#tags`
            once the file is decrypted. These files stay on this Mac.

            Tags, title, body and URL are AES-GCM sealed with the same master key
            that protects the Memory Wave database -- opening a `.md` file
            here directly shows ciphertext, not the page text. Qwave decrypts
            nibbles automatically; there is currently no plaintext export.

            """.write(to: readme, atomically: true, encoding: .utf8)
        }
    }

    @discardableResult
    public func write(_ nibble: MemoryNibble) throws -> URL {
        let cal = Calendar.current
        let parts = cal.dateComponents([.year, .month], from: nibble.created)
        let year = parts.year ?? 1970
        let month = parts.month ?? 1
        let folder =
            directory
            .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        let slug = (nibble.tags.first ?? "nibble")
        let name = "\(safeFile(stamp.string(from: nibble.created)))-\(safeFile(slug))-\(String(nibble.id.prefix(8))).md"
        let url = folder.appendingPathComponent(name)
        try NibbleMarkdown.encode(nibble, key: key).write(to: url, atomically: true, encoding: .utf8)
        QwaveLog.memory.info("Wrote nibble markdown")
        return url
    }

    /// Deletes every nibble markdown file in the vault. The directory and its
    /// `README.md` are left in place — only the plaintext nibbles themselves
    /// go — so a subsequent `write(_:)` has nowhere new to create.
    ///
    /// Mirrors `MemoryStore.deleteAll()`: both must be called together for a
    /// "forget everything" action to actually forget everything, since the
    /// vault is a separate, undeduped mirror of what the store holds.
    public func deleteAll() throws {
        // A re-seal interrupted by a crash can leave a `.reseal-tmp` sibling
        // holding a sealed copy of a nibble. It is not a `.md` file, so the
        // loop below would walk right past it and "forget everything" would
        // leave a memory behind.
        sweepInterruptedReseals()
        for file in try markdownFiles() {
            try? FileManager.default.removeItem(at: file.url)
        }
        // Drop the decode cache too: `all(limit:)` would no longer serve the
        // removed files anyway, but a wipe shouldn't leave their decoded
        // plaintext sitting in memory.
        cache = nil
        QwaveLog.memory.info("Deleted all nibble markdown files")
    }

    public func all(limit: Int = 400) throws -> [MemoryNibble] {
        let files = try markdownFiles()
        // Limits beyond the cache window read directly and skip caching so the
        // stored set never under-serves a larger request.
        guard limit <= Self.cacheLimit else {
            return files.prefix(limit).map(\.url).compactMap { read($0) }
        }
        let window = Array(files.prefix(Self.cacheLimit))
        var nibbles: [URL: MemoryNibble] = [:]
        for (url, mtime) in window {
            if let cached = cache, cached.mtimes[url] == mtime, let nibble = cached.nibbles[url] {
                nibbles[url] = nibble
            } else if let nibble = read(url) {
                nibbles[url] = nibble
            }
        }
        cache = (Dictionary(uniqueKeysWithValues: window.map { ($0.url, $0.mtime) }), nibbles)
        return window.prefix(limit).map(\.url).compactMap { nibbles[$0] }
    }

    private func read(_ url: URL) -> MemoryNibble? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return NibbleMarkdown.decode(text, key: key)
    }

    public func matching(tags: [String], limit: Int = 32) throws -> [MemoryNibble] {
        let wanted = Set(NibbleMarkdown.normalize(tags: tags))
        guard !wanted.isEmpty else { return [] }
        return try all(limit: 400).filter { nibble in
            !wanted.isDisjoint(with: nibble.tags)
        }.prefix(limit).map { $0 }
    }

    public func matching(query: String, limit: Int = 32) throws -> [MemoryNibble] {
        let tags = NibbleMarkdown.tags(inQuery: query)
        if !tags.isEmpty {
            return try matching(tags: tags, limit: limit)
        }
        let needle = query.lowercased()
        guard !needle.isEmpty else { return Array(try all(limit: limit)) }
        return try all(limit: 400).filter { nibble in
            nibble.title.lowercased().contains(needle)
                || nibble.body.lowercased().contains(needle)
                || nibble.tags.contains(where: { $0.contains(needle) })
        }.prefix(limit).map { $0 }
    }

    public func tags(limit: Int = 24) throws -> [String] {
        var counts: [String: Int] = [:]
        for nibble in try all(limit: 400) {
            for tag in nibble.tags {
                counts[tag, default: 0] += 1
            }
        }
        return counts.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }.prefix(limit).map(\.key)
    }

    // MARK: - Re-sealing pre-#107 files (issue #120)

    /// Suffix appended to the destination's name for the sealed replacement.
    /// Deliberately not a `.md` extension and deliberately not hidden:
    /// `markdownFiles()` (and therefore `all`, `deleteAll` and recall) skips
    /// it, while `sweepInterruptedReseals()` -- which does not skip hidden
    /// files either way -- can still find and clear it after a crash.
    static let resealTempSuffix = "reseal-tmp"

    /// Re-seals every nibble whose on-disk form predates the current sealing.
    ///
    /// Ordering guarantees, in the order they matter for user data:
    ///
    /// 1. **Idempotent.** The decision is made per file from its own front
    ///    matter (`NibbleMarkdown.needsReseal`), not from a "migration done"
    ///    flag. A second run rewrites nothing; a *restored backup* or a file
    ///    synced in from another Mac is still upgraded, which a completion
    ///    flag would have skipped forever.
    /// 2. **Atomic.** The replacement is written to a temp file in the same
    ///    directory, flushed, decoded back and compared field-by-field against
    ///    what was read, and only then `rename(2)`d over the original. The
    ///    rename is the single destructive step and it is atomic on APFS, so a
    ///    crash or power loss leaves either the old file or the new one, never
    ///    a truncated one.
    /// 3. **Never lossy.** A file that cannot be read, cannot be decoded with
    ///    this key, or fails the read-back check is left exactly as it was and
    ///    counted. Nothing is ever deleted here: a plaintext memory the user
    ///    still has beats a sealed one they cannot open.
    /// 4. **Resumable.** Interrupting the pass leaves already-renamed files
    ///    sealed and the rest untouched; the next run picks up where it
    ///    stopped, because "needs re-sealing" *is* the resume marker.
    @discardableResult
    public func resealLegacyNibbles() throws -> NibbleResealSummary {
        var summary = NibbleResealSummary()
        sweepInterruptedReseals()
        var rewroteAnything = false
        for file in try markdownFiles() {
            summary.scanned += 1
            guard let text = try? String(contentsOf: file.url, encoding: .utf8) else {
                summary.unreadable += 1
                continue
            }
            guard NibbleMarkdown.needsReseal(text) else {
                summary.alreadySealed += 1
                continue
            }
            guard let nibble = NibbleMarkdown.decode(text, key: key) else {
                // Sealed under a different key, or hand-edited into a shape the
                // decoder rejects. Leave it: rewriting what we cannot read is
                // how a migration destroys memories.
                summary.unreadable += 1
                continue
            }
            if reseal(nibble, at: file.url) {
                summary.resealed += 1
                rewroteAnything = true
            } else {
                summary.failed += 1
            }
        }
        if rewroteAnything { cache = nil }
        QwaveLog.memory.info(
            """
            Vault reseal: scanned \(summary.scanned), resealed \(summary.resealed), \
            already sealed \(summary.alreadySealed), unreadable \(summary.unreadable), \
            failed \(summary.failed)
            """
        )
        return summary
    }

    /// Loads the master key *read-only* and re-seals the vault at `directory`.
    ///
    /// This is the launch entry point, and it re-derives the key itself rather
    /// than trusting a caller to have done so. It never calls
    /// `MemoryCipher.loadOrCreateKey`: that mints a key when the keychain reads
    /// back empty, and minting one here would seal every plaintext nibble under
    /// a key that is *not* the one the rest of the user's memories use -- the
    /// keychain being temporarily unreachable would silently turn into
    /// permanent data loss. A missing or malformed key means the migration does
    /// nothing at all and says so; the plaintext files stay plaintext and stay
    /// readable, which is the recoverable failure.
    public static func resealLegacyNibbles(
        directory: URL, secrets: SecretStore
    ) async -> NibbleResealSummary {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return NibbleResealSummary()
        }
        guard let stored = try? secrets.secret(for: MemoryCipher.keyAccount), stored.count == 32 else {
            QwaveLog.memory.error(
                "Vault reseal skipped: master key unavailable or malformed; nibbles left untouched")
            return NibbleResealSummary(keyLocked: true)
        }
        guard let vault = try? NibbleVault(directory: directory, key: SymmetricKey(data: stored)),
            let summary = try? await vault.resealLegacyNibbles()
        else {
            return NibbleResealSummary()
        }
        return summary
    }

    /// Clears the temp files a previous, interrupted pass left behind. Their
    /// originals are still in place and still authoritative -- the rename that
    /// would have consumed the temp never happened -- so the debris is dropped
    /// and the file is re-sealed from scratch below.
    private func sweepInterruptedReseals() {
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return }
        for case let url as URL in enumerator where url.pathExtension == Self.resealTempSuffix {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Writes `nibble` sealed to a sibling temp file, verifies it decodes back
    /// to the same content, and only then renames it over `url`. Returns false
    /// -- leaving `url` untouched -- if any step fails.
    private func reseal(_ nibble: MemoryNibble, at url: URL) -> Bool {
        let temp = url.appendingPathExtension(Self.resealTempSuffix)
        do {
            let sealed = try NibbleMarkdown.encode(nibble, key: key)
            try? FileManager.default.removeItem(at: temp)
            guard FileManager.default.createFile(atPath: temp.path, contents: nil) else { return false }
            let handle = try FileHandle(forWritingTo: temp)
            try handle.write(contentsOf: Data(sealed.utf8))
            // Flush to the device before the rename, so the commit point cannot
            // publish a file whose bytes are still only in the page cache.
            try handle.synchronize()
            try handle.close()
            // Keep a tightened mode: a user who chmod'ed the vault to 600 must
            // not have it widened by the very pass that seals it.
            if let mode = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] {
                try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: temp.path)
            }
            guard verify(temp, matches: nibble) else {
                try? FileManager.default.removeItem(at: temp)
                return false
            }
            if renameOver(temp, url) { return true }
            try? FileManager.default.removeItem(at: temp)
            return false
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return false
        }
    }

    /// Reads the replacement back off disk and decodes it, so the original is
    /// only replaced by a file that has already been proven readable.
    private func verify(_ temp: URL, matches nibble: MemoryNibble) -> Bool {
        guard
            let text = try? String(contentsOf: temp, encoding: .utf8),
            let decoded = NibbleMarkdown.decode(text, key: key)
        else { return false }
        // `created` round-trips through ISO8601, which is second-resolution; a
        // pre-#107 file with no `created:` field at all decodes to "now", so
        // compare with a one-second tolerance rather than for equality.
        return decoded.id == nibble.id
            && decoded.title == nibble.title
            && decoded.body == nibble.body
            && decoded.tags == nibble.tags
            && decoded.url == nibble.url
            && decoded.kind == nibble.kind
            && decoded.lane == nibble.lane
            && decoded.containerID == nibble.containerID
            && abs(decoded.created.timeIntervalSince(nibble.created)) < 1
    }

    /// `rename(2)`, not `FileManager.moveItem`: the destination exists, and the
    /// replacement has to be a single atomic step rather than a remove followed
    /// by a move, which has a window where the memory is on disk nowhere.
    private func renameOver(_ temp: URL, _ destination: URL) -> Bool {
        temp.withUnsafeFileSystemRepresentation { from in
            guard let from else { return false }
            return destination.withUnsafeFileSystemRepresentation { to in
                guard let to else { return false }
                return rename(from, to) == 0
            }
        }
    }

    private func markdownFiles() throws -> [(url: URL, mtime: Date)] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }
        var files: [(url: URL, mtime: Date)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "md", url.lastPathComponent != "README.md" else { continue }
            let date =
                (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            files.append((url, date))
        }
        return files.sorted { $0.mtime > $1.mtime }
    }

    private func safeFile(_ raw: String) -> String {
        let scalars = raw.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
            return "-"
        }
        let cleaned = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cleaned.isEmpty ? "nibble" : String(cleaned.prefix(40))
    }
}
