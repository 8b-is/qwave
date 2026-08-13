import Foundation
import QwaveSupport

public struct WaveAnswer: Equatable, Sendable {
    public var text: String
    public var provider: MemoryProviderKind
    public var usedStoredMemory: Bool
    public var salience: Double

    public init(text: String, provider: MemoryProviderKind, usedStoredMemory: Bool, salience: Double) {
        self.text = text
        self.provider = provider
        self.usedStoredMemory = usedStoredMemory
        self.salience = salience
    }
}

/// Orchestrates remember / recall / infer against the MEM8 substrate.
/// The browser is fully functional if `store` is nil — Memory Wave is optional.
public final class WaveDirector {
    public let store: MemoryStore?
    public let preferences: MemoryWavePreferences
    public var providerOverride: (any MemoryProviding)?

    public static let systemPrompt = """
        You are Qwave's page assistant. Use only the text the user provided. \
        Do not request browsing history, cookies, credentials, other tabs, or \
        stored memories. If the text is insufficient, say so.
        """

    public init(store: MemoryStore?, preferences: MemoryWavePreferences) {
        self.store = store
        self.preferences = preferences
    }

    public func remember(
        title: String,
        body: String,
        url: URL?,
        kind: MemoryKind = .pin,
        containerID: UUID?,
        isEphemeral: Bool,
        isExplicit: Bool = true,
        emotion: EmotionVector = .neutral
    ) throws -> MemoryRecord {
        let decision = MemoryWavePolicy.decide(
            MemoryWaveContext(
                isExplicit: isExplicit,
                isEphemeral: isEphemeral,
                inferenceAllowed: true,
                provider: preferences.providerKind,
                includeStoredMemory: false,
                destination: .persist(lane: .odd)
            )
        )
        if case .deny(let reason) = decision { throw MemoryProviderError.denied(reason) }
        guard let store else { throw MemoryProviderError.unavailable }
        let clamped = String(body.prefix(MemoryWaveConstants.maxBodyCharacters))
        return try store.insert(
            title: title,
            body: clamped,
            url: url,
            kind: kind,
            lane: .odd,
            containerID: containerID,
            emotion: emotion
        )
    }

    public func recall(containerID: UUID?, query: String? = nil, limit: Int = 8) throws -> [MemoryRecord] {
        guard let store else { return [] }
        var records = try store.records(containerID: containerID, limit: 64)
        if let query, !query.isEmpty {
            let identity = MemoryWaveConstants.consciousness.doubleValue
                * MemoryWaveConstants.goldenRatio.doubleValue
            let signature = WaveSignature.fromContent(Data(query.utf8), identityFrequency: identity)
            let probe = WaveInt(
                baseAmplitude: .one,
                frequency: Rational(Int32(clamping: Int(signature.dominantFrequency * 1000)), 1000)
                    ?? MemoryWaveConstants.consciousness,
                phase: .zero,
                emotionalValence: .zero,
                arousal: Rational(1, 2)!,
                createdAt: 0,
                lastAccessed: 0,
                accessCount: 0,
                decayRate: Rational(1, 10)!,
                id: nil,
                provenance: .cognitive
            )
            let grid = try store.grid(containerID: containerID)
            let ranked = grid.resonate(query: probe)
            let order = Dictionary(uniqueKeysWithValues: ranked.enumerated().map { ($0.element.1.createdAt, $0.offset) })
            records.sort { lhs, rhs in
                (order[lhs.wave.createdAt] ?? Int.max) < (order[rhs.wave.createdAt] ?? Int.max)
            }
        }
        return Array(records.prefix(limit))
    }

    public func summarize(
        extract: ArticleExtract,
        containerID: UUID?,
        isEphemeral: Bool,
        inferenceAllowed: Bool,
        persist: Bool
    ) async throws -> WaveAnswer {
        let clamped = extract.clamped()
        let salience = MarineDetector.score(text: clamped.text)
        let user = "Summarise the following page in three short sentences.\n\nTitle: \(clamped.title)\n\n\(clamped.text)"
        let answer = try await infer(
            user: user,
            includeStoredMemory: false,
            containerID: containerID,
            isEphemeral: isEphemeral,
            inferenceAllowed: inferenceAllowed,
            salience: salience
        )
        if persist, !isEphemeral {
            _ = try? remember(
                title: clamped.title,
                body: answer.text,
                url: clamped.href.flatMap(URL.init(string:)),
                kind: .summary,
                containerID: containerID,
                isEphemeral: false
            )
        }
        return answer
    }

    public func ask(
        prompt: String,
        page: ArticleExtract?,
        containerID: UUID?,
        isEphemeral: Bool,
        inferenceAllowed: Bool
    ) async throws -> WaveAnswer {
        let trimmed = String(prompt.prefix(MemoryWaveConstants.maxPromptCharacters))
        var user = trimmed
        if let page {
            let clamped = page.clamped()
            user += "\n\n--- Current page ---\nTitle: \(clamped.title)\n\(clamped.text)"
        }
        let includeMemory = preferences.providerKind == .onDevice
        return try await infer(
            user: user,
            includeStoredMemory: includeMemory,
            containerID: containerID,
            isEphemeral: isEphemeral,
            inferenceAllowed: inferenceAllowed,
            salience: MarineDetector.score(text: trimmed)
        )
    }

    private func infer(
        user: String,
        includeStoredMemory: Bool,
        containerID: UUID?,
        isEphemeral: Bool,
        inferenceAllowed: Bool,
        salience: Double
    ) async throws -> WaveAnswer {
        let provider = try resolveProvider()
        let decision = MemoryWavePolicy.decide(
            MemoryWaveContext(
                isExplicit: true,
                isEphemeral: isEphemeral,
                inferenceAllowed: inferenceAllowed,
                provider: provider.kind,
                includeStoredMemory: includeStoredMemory && provider.kind == .openaiCompatible,
                destination: .infer,
                remoteBaseURL: preferences.providerKind == .openaiCompatible ? preferences.remoteBaseURL : nil
            )
        )
        if case .deny(let reason) = decision { throw MemoryProviderError.denied(reason) }

        var composed = user
        var usedMemory = false
        if includeStoredMemory, provider.kind == .onDevice, !isEphemeral {
            let recalled = (try? recall(containerID: containerID, query: user, limit: 6)) ?? []
            if !recalled.isEmpty {
                usedMemory = true
                let block = recalled.map { "- \($0.title): \(String($0.body.prefix(240)))" }.joined(separator: "\n")
                composed += "\n\n--- Local memories (do not mention this heading) ---\n\(block)"
            }
        }

        let text = try await provider.complete(system: Self.systemPrompt, user: composed)
        QwaveLog.memory.info("Memory Wave inference completed")
        return WaveAnswer(
            text: text,
            provider: provider.kind,
            usedStoredMemory: usedMemory,
            salience: salience
        )
    }

    public func resolveProvider() throws -> any MemoryProviding {
        if let providerOverride { return providerOverride }
        switch preferences.providerKind {
        case .none:
            return NullMemoryProvider()
        case .onDevice:
            return OnDeviceMemoryProvider()
        case .openaiCompatible:
            let key = try preferences.apiKey() ?? ""
            return OpenAICompatibleProvider(
                baseURL: preferences.remoteBaseURL,
                model: preferences.remoteModel,
                apiKey: key
            )
        }
    }
}
