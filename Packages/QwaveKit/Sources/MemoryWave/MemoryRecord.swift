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
        self.tags = tags
    }

    /// Recomputed on demand from `title`/`body`. This is a ~1000-step, 8-harmonic
    /// trig reconstruction (`WaveSignature.fromContent`), so it is deliberately
    /// *not* a stored/eager property: nothing in the store's decode or ranking
    /// path reads it, and callers that do need it (e.g. tests calling `verify()`)
    /// pay the cost only when they actually ask for it.
    public var signature: WaveSignature {
        WaveSignature.fromContent(
            Data((title + "\n" + body).utf8),
            identityFrequency:
                MemoryWaveConstants.consciousness.doubleValue * MemoryWaveConstants.goldenRatio.doubleValue
        )
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
