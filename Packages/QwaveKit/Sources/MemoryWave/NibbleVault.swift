import CryptoKit
import Foundation
import QwaveSupport

/// Tag-indexed, local-only vault of nibbles, stored as `.md` files whose
/// title/body/url are AES-GCM sealed with the same Memory Wave master key
/// that seals `MemoryStore` (issue #81). Only short, low-sensitivity
/// metadata -- tags, kind, lane, timestamps -- stays in the clear, since the
/// vault needs it for tag search and file naming without decrypting every
/// file. The vault used to mirror the sealed database body as plaintext
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
            in the front matter. These files stay on this Mac.

            Title, body and URL are AES-GCM sealed with the same master key
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
