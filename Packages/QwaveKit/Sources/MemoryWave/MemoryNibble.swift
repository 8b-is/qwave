import CryptoKit
import Foundation

/// A bite-sized Cognitive unit: tagged markdown that wave recall can hit.
public struct MemoryNibble: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var body: String
    public var tags: [String]
    public var url: URL?
    public var created: Date
    public var kind: MemoryKind
    public var containerID: UUID?
    public var lane: MemoryLane
    public var wave: WaveInt

    public init(
        id: String = UUID().uuidString.lowercased(),
        title: String,
        body: String,
        tags: [String],
        url: URL?,
        created: Date = Date(),
        kind: MemoryKind,
        containerID: UUID?,
        lane: MemoryLane = .odd,
        wave: WaveInt? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.tags = NibbleMarkdown.normalize(tags: tags)
        self.url = url
        self.created = created
        self.kind = kind
        self.containerID = containerID
        self.lane = lane
        self.wave = wave ?? NibbleMarkdown.wave(for: title + "\n" + body, created: created)
    }

    public func asRecord() -> MemoryRecord {
        MemoryRecord(
            id: Int64(bitPattern: UInt64(truncatingIfNeeded: id.hashValue)),
            containerID: containerID,
            kind: .nibble,
            lane: lane,
            created: created,
            url: url,
            title: title,
            body: body,
            wave: wave,
            tags: tags
        )
    }
}

public enum NibbleMarkdown {
    public static func normalize(_ raw: String) -> String? {
        let folded = raw.lowercased()
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: " ", with: "-")
        let allowed = folded.unicodeScalars.map { scalar -> Character? in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" {
                return Character(scalar)
            }
            return nil
        }
        let slug = String(allowed.compactMap { $0 })
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? nil : String(slug.prefix(32))
    }

    public static func normalize(tags: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in tags {
            guard let slug = normalize(tag), !seen.contains(slug) else { continue }
            seen.insert(slug)
            result.append(slug)
        }
        return result
    }

    public static func tags(inQuery query: String) -> [String] {
        let parts = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let hashed = parts.compactMap { part -> String? in
            part.hasPrefix("#") ? normalize(part) : nil
        }
        if !hashed.isEmpty { return hashed }
        if query.hasPrefix("tag:") {
            return normalize(tags: [String(query.dropFirst(4))])
        }
        return []
    }

    public static func hashtags(in text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "#" && $0 != "-" })
            .map(String.init)
            .filter { $0.hasPrefix("#") && $0.count > 1 }
            .compactMap(normalize)
    }

    /// Marker written into the `sealed:` front-matter field so `decode` can
    /// tell an AES-GCM-sealed nibble apart from a pre-#81 plaintext one.
    public static let sealedMarker = "aes-gcm-256"

    /// Encodes a nibble as front-matter + AES-GCM-sealed tags/title/body/url,
    /// keyed by the same Memory Wave master key that seals `MemoryStore`
    /// (issue #81: the vault used to mirror the sealed DB body as plaintext
    /// markdown on disk). Only `kind`, `lane`, `created`, `id` and `container`
    /// stay in the clear -- content-free bookkeeping the vault needs for file
    /// naming and ordering. Opening the `.md` file outside Qwave shows
    /// ciphertext, not the page text.
    ///
    /// The tags are sealed too, though they were left in the clear when the
    /// rest was sealed: they are *derived from the content* -- the URL host and
    /// the words of the title (`NibbleCutter.tags`) -- so a nibble for a
    /// medical page published the host and the diagnosis words on disk in the
    /// same file that claimed to hold only ciphertext. Sealing them costs no
    /// recall: `NibbleVault.matching(tags:)` reaches them through `all(limit:)`,
    /// which already reads and decodes every file, so nothing ever searched the
    /// front matter without decrypting it.
    public static func encode(_ nibble: MemoryNibble, key: SymmetricKey) throws -> String {
        let tagsSealed =
            try MemoryCipher.seal(Data(nibble.tags.joined(separator: ", ").utf8), key: key)
            .base64EncodedString()
        let created = ISO8601DateFormatter().string(from: nibble.created)
        let container = nibble.containerID?.uuidString ?? ""
        let titleSealed = try MemoryCipher.seal(Data(nibble.title.utf8), key: key).base64EncodedString()
        let urlSealed =
            try nibble.url.map {
                try MemoryCipher.seal(Data($0.absoluteString.utf8), key: key).base64EncodedString()
            } ?? ""
        let bodySealed = try MemoryCipher.seal(Data(nibble.body.utf8), key: key).base64EncodedString()
        return """
            ---
            id: \(nibble.id)
            kind: nibble
            source: \(nibble.kind.rawValue)
            tags_sealed: \(tagsSealed)
            url_sealed: \(urlSealed)
            created: \(created)
            container: \(container)
            lane: \(nibble.lane.rawValue)
            sealed: \(sealedMarker)
            title_sealed: \(titleSealed)
            ---

            \(bodySealed)

            """
    }

    /// Decodes a nibble written by `encode(_:key:)`. Falls back to the
    /// pre-#81 plaintext format (`# Title` heading, plain `url:`) so nibbles
    /// written before this fix keep decoding -- they are not silently
    /// dropped from recall, they simply were never sealed to begin with.
    public static func decode(_ text: String, key: SymmetricKey) -> MemoryNibble? {
        guard let (fields, bodyText) = frontMatter(text) else { return nil }
        // `tags_sealed` is the current layout; `tags` is the plaintext list
        // written before the tags were sealed (and by the pre-#81 format), kept
        // readable so those files are not dropped from recall.
        let tags: [String]
        if let sealedTags = fields["tags_sealed"], !sealedTags.isEmpty,
            let tagsBox = Data(base64Encoded: sealedTags),
            let tagsData = try? MemoryCipher.open(tagsBox, key: key),
            let tagList = String(data: tagsData, encoding: .utf8)
        {
            tags = parseTagList(tagList)
        } else {
            tags = parseTagList(fields["tags"] ?? "")
        }
        let created = fields["created"].flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
        let kind = fields["source"].flatMap(MemoryKind.init(rawValue:)) ?? .nibble
        let container = fields["container"].flatMap { $0.isEmpty ? nil : UUID(uuidString: $0) }
        let lane = fields["lane"].flatMap(MemoryLane.init(rawValue:)) ?? .odd
        let id = fields["id"].flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString.lowercased()

        guard fields["sealed"] == sealedMarker else {
            return decodeLegacyPlaintext(
                bodyText: bodyText, fields: fields, tags: tags, created: created,
                kind: kind, container: container, lane: lane, id: id)
        }

        guard
            let titleB64 = fields["title_sealed"], !titleB64.isEmpty,
            let titleBox = Data(base64Encoded: titleB64),
            let titleData = try? MemoryCipher.open(titleBox, key: key),
            let title = String(data: titleData, encoding: .utf8),
            let bodyBox = Data(base64Encoded: bodyText),
            let bodyData = try? MemoryCipher.open(bodyBox, key: key),
            let body = String(data: bodyData, encoding: .utf8)
        else { return nil }
        var url: URL?
        if let urlB64 = fields["url_sealed"], !urlB64.isEmpty,
            let urlBox = Data(base64Encoded: urlB64),
            let urlData = try? MemoryCipher.open(urlBox, key: key)
        {
            url = String(data: urlData, encoding: .utf8).flatMap(URL.init(string:))
        }
        return MemoryNibble(
            id: id, title: title, body: body, tags: tags, url: url, created: created,
            kind: kind, containerID: container, lane: lane
        )
    }

    /// Splits `---` front matter from the body. Shared by `decode` and
    /// `needsReseal(_:)` so the migration decides on exactly the fields the
    /// decoder reads, rather than on a second, drifting parser.
    private static func frontMatter(_ text: String) -> (fields: [String: String], body: String)? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else { return nil }
        let rest = normalized.dropFirst(4)
        guard let end = rest.range(of: "\n---\n") else { return nil }
        let header = String(rest[..<end.lowerBound])
        let bodyText = String(rest[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        var fields: [String: String] = [:]
        for line in header.split(whereSeparator: \.isNewline) {
            let raw = String(line)
            guard let colon = raw.firstIndex(of: ":") else { continue }
            let fieldKey = String(raw[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(raw[raw.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            fields[fieldKey] = value
        }
        return (fields, bodyText)
    }

    /// True when this file's front matter predates the current sealing and the
    /// vault should rewrite it (issue #120).
    ///
    /// Two generations qualify: pre-#107 files with no `sealed:` marker at all
    /// (title, body and `url:` in the clear), and the files written between
    /// #107 and the tag sealing, which carry `sealed:` but publish the derived
    /// host/title words through a plaintext `tags:` line. `tags_sealed` is
    /// never empty for a file this encoder wrote -- sealing an empty tag list
    /// still yields a 28-byte box -- so an empty value means "not written by
    /// the current encoder", not "no tags".
    ///
    /// Anything that is not front-matter markdown at all returns `false`: the
    /// migration's job is to upgrade nibbles, never to touch files it does not
    /// recognise.
    public static func needsReseal(_ text: String) -> Bool {
        guard let (fields, _) = frontMatter(text) else { return false }
        if fields["sealed"] != sealedMarker { return true }
        return (fields["tags_sealed"] ?? "").isEmpty
    }

    private static func decodeLegacyPlaintext(
        bodyText: String, fields: [String: String], tags: [String], created: Date,
        kind: MemoryKind, container: UUID?, lane: MemoryLane, id: String
    ) -> MemoryNibble? {
        var title = fields["title"] ?? ""
        var body = bodyText
        if body.hasPrefix("# ") {
            if let nl = body.firstIndex(of: "\n") {
                title = String(body[body.index(body.startIndex, offsetBy: 2)..<nl])
                    .trimmingCharacters(in: .whitespaces)
                body = String(body[body.index(after: nl)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                title = String(body.dropFirst(2))
                body = ""
            }
        }
        let url = fields["url"].flatMap { $0.isEmpty ? nil : URL(string: $0) }
        return MemoryNibble(
            id: id,
            title: title.isEmpty ? "nibble" : title,
            body: body,
            tags: tags,
            url: url,
            created: created,
            kind: kind,
            containerID: container,
            lane: lane
        )
    }

    public static func wave(for text: String, created: Date) -> WaveInt {
        let signature = WaveSignature.fromContent(
            Data(text.utf8),
            identityFrequency: MemoryWaveConstants.consciousness.doubleValue
                * MemoryWaveConstants.goldenRatio.doubleValue
        )
        let hz = signature.dominantFrequency
        let milli = Int32(clamping: Int((hz * 1000).rounded()))
        return WaveInt(
            baseAmplitude: .one,
            frequency: Rational(max(1, milli), 1000) ?? MemoryWaveConstants.consciousness,
            phase: .zero,
            emotionalValence: .zero,
            arousal: Rational(1, 2)!,
            createdAt: WaveInt.nanosecondsSince1970(created),
            lastAccessed: WaveInt.nanosecondsSince1970(created),
            accessCount: 1,
            decayRate: Rational(1, 10)!,
            id: nil,
            provenance: .cognitive
        )
    }

    private static func parseTagList(_ raw: String) -> [String] {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("[") { s.removeFirst() }
        if s.hasSuffix("]") { s.removeLast() }
        return normalize(tags: s.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
    }
}
