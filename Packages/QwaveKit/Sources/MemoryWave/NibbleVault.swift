import Foundation
import QwaveSupport

/// Markdown-on-disk vault of nibbles. Human-readable, tag-indexed, local only.
///
/// An actor so the enumeration + file reads in `all(limit:)` run off the main
/// thread when awaited from `@MainActor` callers, and so the decode cache is
/// mutated under serialized isolation.
public actor NibbleVault {
    public nonisolated let directory: URL

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

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let readme = directory.appendingPathComponent("README.md")
        if !FileManager.default.fileExists(atPath: readme.path) {
            try """
            # Memory Wave nibbles

            Each file is a tagged Cognitive nibble. Wave recall matches `#tags`
            in the front matter. These files stay on this Mac.

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
        try NibbleMarkdown.encode(nibble).write(to: url, atomically: true, encoding: .utf8)
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
        return NibbleMarkdown.decode(text)
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
