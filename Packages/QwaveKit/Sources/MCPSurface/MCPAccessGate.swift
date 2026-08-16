import Foundation
import Persistence

/// The opt-in gate for the MCP surface. **Closed unless the user opened it.**
///
/// This is the same shape every other opt-in in Qwave uses (see
/// `SettingsStore.networkSuggestionsEnabled`): a namespaced `qwave.*` key read
/// with `object(forKey:) as? Bool ?? false`, so an absent key — the state of
/// every machine that has never been told otherwise — reads as OFF.
///
/// The one thing that is different here is *which* defaults domain is read.
/// `qwave-mcp` is a standalone executable; its own `UserDefaults.standard` is
/// its own domain and would never see a value the app wrote. So the gate names
/// the app's domain (`is.8b.qwave`) explicitly. If that suite cannot be opened
/// at all, the gate stays closed — a missing preference store is not consent.
///
/// `@unchecked Sendable` for the same reason `MemoryWavePreferences` is: the
/// only stored state is a `let` `UserDefaults`, which is documented as
/// thread-safe but carries no `Sendable` conformance in the SDK.
public final class MCPAccessGate: @unchecked Sendable {
    private let defaults: UserDefaults?
    private let fixedAnswer: Bool?

    /// Reads the live app preference domain.
    public init(suiteName: String = QwaveProfileLocation.applicationDefaultsSuite) {
        defaults = UserDefaults(suiteName: suiteName)
        fixedAnswer = nil
    }

    /// Reads an injected defaults instance — used by tests and by any future
    /// caller that already holds the app's suite.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
        fixedAnswer = nil
    }

    private init(fixedAnswer: Bool) {
        defaults = nil
        self.fixedAnswer = fixedAnswer
    }

    /// A gate with a fixed answer. Tests use this; production does not.
    public static func fixed(_ enabled: Bool) -> MCPAccessGate {
        MCPAccessGate(fixedAnswer: enabled)
    }

    /// Re-read on every call, never cached: the user can revoke consent in
    /// Settings while a long-lived server process is still attached, and the
    /// next tool call must see that.
    public var isEnabled: Bool {
        if let fixedAnswer { return fixedAnswer }
        return defaults?.object(forKey: SettingsStore.mcpServerEnabledKey) as? Bool ?? false
    }

    /// What to tell a caller that arrives while the gate is shut. Deliberately
    /// says nothing about whether a profile exists or what is in it.
    public static let disabledMessage = """
        Qwave's MCP surface is turned off. It is off by default because it \
        exposes browsing history to any process that can run this binary. \
        Enable it in Qwave under Settings, or with: \
        defaults write \(QwaveProfileLocation.applicationDefaultsSuite) \
        \(SettingsStore.mcpServerEnabledKey) -bool true
        """
}
