import Foundation

public enum MemoryKind: String, Sendable, Equatable {
    case pin
    case summary
    case note
    /// Automatic capture from Remember Everything. Deduped per URL.
    case browse
    /// Tagged markdown nibble — retrieval unit for wave memory.
    case nibble
}

public struct MemoryRecord: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var containerID: UUID?
    public var kind: MemoryKind
    public var lane: MemoryLane
    public var created: Date
    public var url: URL?
    public var title: String
    public var body: String
    public var wave: WaveInt
    public var signature: WaveSignature
    public var tags: [String]

    public init(
        id: Int64,
        containerID: UUID?,
        kind: MemoryKind,
        lane: MemoryLane,
        created: Date,
        url: URL?,
        title: String,
        body: String,
        wave: WaveInt,
        signature: WaveSignature,
        tags: [String] = []
    ) {
        self.id = id
        self.containerID = containerID
        self.kind = kind
        self.lane = lane
        self.created = created
        self.url = url
        self.title = title
        self.body = body
        self.wave = wave
        self.signature = signature
        self.tags = tags
    }
}

public struct ArticleExtract: Equatable, Sendable {
    public var title: String
    public var text: String
    public var href: String?

    public init(title: String, text: String, href: String? = nil) {
        self.title = title
        self.text = text
        self.href = href
    }

    public func clamped(maxChars: Int = MemoryWaveConstants.maxPageCharacters) -> ArticleExtract {
        var copy = self
        if copy.text.count > maxChars {
            copy.text = String(copy.text.prefix(maxChars))
        }
        return copy
    }
}
