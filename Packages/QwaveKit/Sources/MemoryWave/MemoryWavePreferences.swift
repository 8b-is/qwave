import Foundation
import Persistence
import QwaveSupport

/// Typed Memory Wave preferences. API keys live in SecretStore, never defaults.
///
/// `Sendable` because `EgressGuard` reads ``egressPermittedHost`` from whatever
/// queue `URLSession` runs its protocol on, while everything else here is on
/// the main actor. Both stored properties are `let`s of thread-safe types —
/// `SecretStore` is itself `Sendable`, and `UserDefaults` is documented as
/// thread-safe but carries no `Sendable` conformance in the SDK, which is the
/// one thing `@unchecked` is covering here.
public final class MemoryWavePreferences: @unchecked Sendable {
    public static let defaultRemoteBaseURL = URL(string: "https://api.x.ai/v1")!
    public static let defaultRemoteModel = "grok-4.6"
    public static let apiKeyAccount = "memorywave.openai.api-key"

    private let defaults: UserDefaults
    private let secrets: SecretStore

    private enum Key {
        static let provider = "qwave.memory.provider"
        static let remoteBaseURL = "qwave.memory.remoteBaseURL"
        static let remoteModel = "qwave.memory.remoteModel"
        static let rememberEverything = "qwave.memory.rememberEverything"
    }

    public init(defaults: UserDefaults = .standard, secrets: SecretStore) {
        self.defaults = defaults
        self.secrets = secrets
    }

    public var providerKind: MemoryProviderKind {
        get {
            defaults.string(forKey: Key.provider).flatMap(MemoryProviderKind.init(rawValue:)) ?? .none
        }
        set { defaults.set(newValue.rawValue, forKey: Key.provider) }
    }

    public var remoteBaseURL: URL {
        get {
            defaults.string(forKey: Key.remoteBaseURL).flatMap(URL.init(string:)) ?? Self.defaultRemoteBaseURL
        }
        set { defaults.set(newValue.absoluteString, forKey: Key.remoteBaseURL) }
    }

    public var remoteModel: String {
        get {
            let value = defaults.string(forKey: Key.remoteModel) ?? ""
            return value.isEmpty ? Self.defaultRemoteModel : value
        }
        set { defaults.set(newValue, forKey: Key.remoteModel) }
    }

    /// Opt-in local auto-capture of every non-ephemeral page. Off by default.
    public var rememberEverything: Bool {
        get { defaults.bool(forKey: Key.rememberEverything) }
        set { defaults.set(newValue, forKey: Key.rememberEverything) }
    }

    /// The one host `EgressGuard` may let Memory Wave's own provider request
    /// reach, or `nil` when no remote endpoint is configured. Read live by the
    /// guard on every request (see `EgressUserConfiguredEndpoint`), which is
    /// why it is derived here rather than pushed anywhere: the instant Settings
    /// writes `providerKind` or `remoteBaseURL`, this changes with it, and the
    /// previous host stops being permitted without anyone firing an event.
    public var egressPermittedHost: String? {
        providerKind == .openaiCompatible ? remoteBaseURL.host : nil
    }

    public func apiKey() throws -> String? {
        guard let data = try secrets.secret(for: Self.apiKeyAccount) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setAPIKey(_ key: String?) throws {
        if let key, !key.isEmpty {
            try secrets.setSecret(Data(key.utf8), for: Self.apiKeyAccount)
        } else {
            try secrets.removeSecret(for: Self.apiKeyAccount)
        }
    }
}
