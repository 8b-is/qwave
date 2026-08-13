import Foundation
import QwaveSupport

/// Markdown-on-disk vault of nibbles. Human-readable, tag-indexed, local only.
public final class NibbleVault {
    public let directory: URL

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

    public func all(limit: Int = 400) throws -> [MemoryNibble] {
        let files = try markdownFiles()
        return files.prefix(limit).compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return NibbleMarkdown.decode(text)
        }
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

    private func markdownFiles() throws -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }
        var files: [(URL, Date)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "md", url.lastPathComponent != "README.md" else { continue }
            let date =
                (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            files.append((url, date))
        }
        return files.sorted { $0.1 > $1.1 }.map(\.0)
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
