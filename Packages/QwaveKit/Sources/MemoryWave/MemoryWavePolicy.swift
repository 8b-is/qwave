import Foundation

/// Even/odd storage lane (MEM8 even/odd blocks).
/// Odd = raw private experience. Even = consolidated, still local.
public enum MemoryLane: String, Sendable, Equatable {
    case odd
    case even
}

public enum MemoryProviderKind: String, Sendable, Equatable, CaseIterable {
    case none
    case onDevice
    case openaiCompatible
}

public enum MemoryDestination: Sendable, Equatable {
    case persist(lane: MemoryLane)
    case infer
}

public enum MemoryWaveDenial: String, Sendable, Equatable {
    case notExplicit
    case ephemeral
    case energy
    case providerDisabled
    case cognitiveEgress
    case insecureEndpoint
}

public enum MemoryWaveDecision: Sendable, Equatable {
    case allow
    case deny(MemoryWaveDenial)
}

public struct MemoryWaveContext: Sendable, Equatable {
    public var isExplicit: Bool
    public var isEphemeral: Bool
    public var inferenceAllowed: Bool
    public var provider: MemoryProviderKind
    public var includeStoredMemory: Bool
    public var destination: MemoryDestination
    /// Remote base URL, if the chosen provider talks to a network.
    public var remoteBaseURL: URL?
    /// User opted into local auto-capture. Still never writes ephemeral tabs.
    public var rememberEverything: Bool

    public init(
        isExplicit: Bool,
        isEphemeral: Bool,
        inferenceAllowed: Bool,
        provider: MemoryProviderKind,
        includeStoredMemory: Bool,
        destination: MemoryDestination,
        remoteBaseURL: URL? = nil,
        rememberEverything: Bool = false
    ) {
        self.isExplicit = isExplicit
        self.isEphemeral = isEphemeral
        self.inferenceAllowed = inferenceAllowed
        self.provider = provider
        self.includeStoredMemory = includeStoredMemory
        self.destination = destination
        self.remoteBaseURL = remoteBaseURL
        self.rememberEverything = rememberEverything
    }
}

/// Fail-closed policy. Stored Cognitive waves never leave this Mac.
public enum MemoryWavePolicy {
    public static func decide(_ context: MemoryWaveContext) -> MemoryWaveDecision {
        switch context.destination {
        case .persist:
            if context.isEphemeral { return .deny(.ephemeral) }
            if context.isExplicit || context.rememberEverything { return .allow }
            return .deny(.notExplicit)

        case .infer:
            guard context.isExplicit else { return .deny(.notExplicit) }
            if !context.inferenceAllowed { return .deny(.energy) }
            if context.provider == .none { return .deny(.providerDisabled) }
            if context.provider == .openaiCompatible {
                if context.includeStoredMemory { return .deny(.cognitiveEgress) }
                if let url = context.remoteBaseURL, url.scheme?.lowercased() != "https" {
                    return .deny(.insecureEndpoint)
                }
            }
            return .allow
        }
    }

    /// Remote inference may carry the current prompt and optional current page.
    /// It must never carry stored Cognitive waves.
    public static func remotePayloadAllowed(includeStoredMemory: Bool) -> Bool {
        !includeStoredMemory
    }
}
