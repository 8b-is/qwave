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

    public static func encode(_ nibble: MemoryNibble) -> String {
        let tagList = nibble.tags.joined(separator: ", ")
        let created = ISO8601DateFormatter().string(from: nibble.created)
        let url = nibble.url?.absoluteString ?? ""
        let container = nibble.containerID?.uuidString ?? ""
        return """
            ---
            id: \(nibble.id)
            kind: nibble
            source: \(nibble.kind.rawValue)
            tags: [\(tagList)]
            url: \(url)
            created: \(created)
            container: \(container)
            lane: \(nibble.lane.rawValue)
            ---

            # \(nibble.title)

            \(nibble.body)

            """
    }

    public static func decode(_ text: String) -> MemoryNibble? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else { return nil }
        let rest = normalized.dropFirst(4)
        guard let end = rest.range(of: "\n---\n") else { return nil }
        let header = String(rest[..<end.lowerBound])
        var body = String(rest[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        var fields: [String: String] = [:]
        for line in header.split(whereSeparator: \.isNewline) {
            let raw = String(line)
            guard let colon = raw.firstIndex(of: ":") else { continue }
            let key = String(raw[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(raw[raw.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }
        var title = fields["title"] ?? ""
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
        let tags = parseTagList(fields["tags"] ?? "")
        let created = fields["created"].flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
        let url = fields["url"].flatMap { $0.isEmpty ? nil : URL(string: $0) }
        let kind = fields["source"].flatMap(MemoryKind.init(rawValue:)) ?? .nibble
        let container = fields["container"].flatMap { $0.isEmpty ? nil : UUID(uuidString: $0) }
        let lane = fields["lane"].flatMap(MemoryLane.init(rawValue:)) ?? .odd
        let id = fields["id"].flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString.lowercased()
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
