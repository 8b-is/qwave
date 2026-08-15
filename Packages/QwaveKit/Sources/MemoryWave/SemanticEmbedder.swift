import CryptoKit
import Foundation

#if canImport(NaturalLanguage)
    import NaturalLanguage
#endif

/// A mean-pooled, L2-normalised contextual embedding for one memory or query.
///
/// Normalising at construction means `cosineSimilarity` reduces to a dot
/// product, which is what the reranker needs.
public struct SemanticVector: Equatable, Sendable {
    /// Unit-length embedding (empty only for the degenerate zero vector).
    public let values: [Float]

    public init(_ raw: [Float]) {
        var norm: Float = 0
        for value in raw { norm += value * value }
        norm = norm.squareRoot()
        if norm > 0 {
            values = raw.map { $0 / norm }
        } else {
            values = raw
        }
    }

    /// Cosine similarity in `[-1, 1]`. Zero when the vectors disagree in
    /// dimension so a malformed pair can never bias the ranking.
    public func cosineSimilarity(to other: SemanticVector) -> Double {
        guard values.count == other.values.count, !values.isEmpty else { return 0 }
        var dot: Double = 0
        for i in values.indices { dot += Double(values[i]) * Double(other.values[i]) }
        return dot
    }
}

/// Reranks resonance candidates by semantic closeness to the query.
public enum SemanticReranker {
    /// Reorders `candidates` by descending cosine similarity to `query`.
    ///
    /// Candidates whose embedding is `nil` (asset gap, empty text, or a script
    /// the model does not cover) keep their original relative order and sit
    /// after every scored candidate — the lexical prefilter order survives as
    /// the tail, so recall degrades gracefully instead of dropping results.
    public static func rerank<Item>(
        query: SemanticVector,
        candidates: [(item: Item, vector: SemanticVector?)]
    ) -> [Item] {
        let scored =
            candidates.enumerated()
            .compactMap { index, candidate -> (Int, Item, Double)? in
                guard let vector = candidate.vector else { return nil }
                return (index, candidate.item, query.cosineSimilarity(to: vector))
            }
            .sorted { lhs, rhs in
                if lhs.2 != rhs.2 { return lhs.2 > rhs.2 }
                return lhs.0 < rhs.0
            }
        let unscored =
            candidates
            .filter { $0.vector == nil }
            .map { $0.item }
        return scored.map { $0.1 } + unscored
    }
}

/// On-device semantic embeddings via `NLContextualEmbedding` (Natural Language,
/// runs on the ANE, fully offline). Mean-pools per-token vectors into one unit
/// vector per memory and caches by content hash so each memory is embedded
/// once.
///
/// Privacy: we only use the model when its assets are ALREADY present
/// (`hasAvailableAssets`); we never call `requestAssets`, so recall never
/// triggers a background download. When the asset is unavailable — or on any
/// platform without Natural Language — `vector(for:)` returns `nil` and callers
/// fall back to lexical ranking.
public actor SemanticEmbedder {
    public init() {}

    private var cache: [Data: SemanticVector] = [:]
    private var state: State = .untried

    private enum State {
        case untried
        case unavailable
        #if canImport(NaturalLanguage)
            case ready(NLContextualEmbedding)
        #endif
    }

    /// A normalised embedding for `text`, or `nil` when the on-device model is
    /// unavailable or the text cannot be embedded. Cached per content hash.
    public func vector(for text: String) -> SemanticVector? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let key = Data(SHA256.hash(data: Data(trimmed.utf8)))
        if let cached = cache[key] { return cached }
        guard let vector = compute(trimmed) else { return nil }
        cache[key] = vector
        return vector
    }

    /// Whether the contextual-embedding asset is loaded and usable. Resolving
    /// this lazily loads the model on first call.
    public var isAvailable: Bool {
        #if canImport(NaturalLanguage)
            return model() != nil
        #else
            return false
        #endif
    }

    #if canImport(NaturalLanguage)
        private func model() -> NLContextualEmbedding? {
            switch state {
            case .ready(let embedding):
                return embedding
            case .unavailable:
                return nil
            case .untried:
                guard
                    let embedding = NLContextualEmbedding(language: .english),
                    embedding.hasAvailableAssets
                else {
                    state = .unavailable
                    return nil
                }
                do {
                    try embedding.load()
                } catch {
                    state = .unavailable
                    return nil
                }
                state = .ready(embedding)
                return embedding
            }
        }

        private func compute(_ text: String) -> SemanticVector? {
            guard let embedding = model() else { return nil }
            guard let result = try? embedding.embeddingResult(for: text, language: nil) else {
                return nil
            }
            let dimension = embedding.dimension
            guard dimension > 0 else { return nil }
            var sum = [Double](repeating: 0, count: dimension)
            var count = 0
            result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
                if vector.count == dimension {
                    for i in 0..<dimension { sum[i] += vector[i] }
                    count += 1
                }
                return true
            }
            guard count > 0 else { return nil }
            let mean = sum.map { Float($0 / Double(count)) }
            return SemanticVector(mean)
        }
    #else
        private func compute(_ text: String) -> SemanticVector? { nil }
    #endif
}
