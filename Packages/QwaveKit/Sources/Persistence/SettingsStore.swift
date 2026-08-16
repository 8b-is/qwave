import Foundation

public enum SearchEngine: String, CaseIterable, Codable, Identifiable, Sendable {
    case duckduckgo
    case brave
    case startpage
    case google
    case kagi

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .duckduckgo: return "DuckDuckGo"
        case .brave: return "Brave Search"
        case .startpage: return "Startpage"
        case .google: return "Google"
        case .kagi: return "Kagi"
        }
    }

    public func searchURL(for query: String) -> URL? {
        guard let escaped = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        switch self {
        case .duckduckgo: return URL(string: "https://duckduckgo.com/?q=\(escaped)")
        case .brave: return URL(string: "https://search.brave.com/search?q=\(escaped)")
        case .startpage: return URL(string: "https://www.startpage.com/sp/search?query=\(escaped)")
        case .google: return URL(string: "https://www.google.com/search?q=\(escaped)")
        case .kagi: return URL(string: "https://kagi.com/search?q=\(escaped)")
        }
    }
}

/// Typed access to user preferences. All keys are namespaced to survive
/// alongside anything else living in the same defaults domain.
@MainActor
public final class SettingsStore {
    private let defaults: UserDefaults

    private enum Key {
        static let searchEngine = "qwave.searchEngine"
        static let httpsFirst = "qwave.httpsFirst"
        static let shieldsEnabled = "qwave.shieldsEnabled"
        static let hibernationTimeout = "qwave.hibernationTimeout"
        static let homepage = "qwave.homepage"
        static let restoreSession = "qwave.restoreSession"
        static let networkSuggestions = "qwave.networkSuggestions"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var searchEngine: SearchEngine {
        get {
            defaults.string(forKey: Key.searchEngine).flatMap(SearchEngine.init(rawValue:)) ?? .duckduckgo
        }
        set { defaults.set(newValue.rawValue, forKey: Key.searchEngine) }
    }

    public var httpsFirstEnabled: Bool {
        get { defaults.object(forKey: Key.httpsFirst) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.httpsFirst) }
    }

    public var shieldsEnabledByDefault: Bool {
        get { defaults.object(forKey: Key.shieldsEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.shieldsEnabled) }
    }

    /// Seconds of background inactivity before a tab becomes eligible for
    /// hibernation. The EnergyGovernor shortens this under thermal pressure.
    public var hibernationTimeout: TimeInterval {
        get {
            let value = defaults.double(forKey: Key.hibernationTimeout)
            return value > 0 ? value : 15 * 60
        }
        set { defaults.set(newValue, forKey: Key.hibernationTimeout) }
    }

    public var homepage: URL? {
        get { defaults.string(forKey: Key.homepage).flatMap(URL.init(string:)) }
        set { defaults.set(newValue?.absoluteString, forKey: Key.homepage) }
    }

    public var restoreSessionOnLaunch: Bool {
        get { defaults.object(forKey: Key.restoreSession) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.restoreSession) }
    }

    /// When ON, the omnibox may send the typed query to the configured search
    /// engine to fetch autocomplete suggestions. Defaults to OFF: on-device
    /// suggestions (history, bookmarks, open tabs, quick actions) never leave
    /// the machine, and nothing is sent per-keystroke unless the user opts in.
    public var networkSuggestionsEnabled: Bool {
        get { defaults.object(forKey: Key.networkSuggestions) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.networkSuggestions) }
    }

    /// The defaults key behind ``mcpServerEnabled``.
    ///
    /// Public, and `nonisolated`, because the reader is a *different process*:
    /// `qwave-mcp` reads this exact key out of the app's defaults domain
    /// (`is.8b.qwave`), since its own `UserDefaults.standard` is a different
    /// domain and would never see what the app wrote. One key constant, so the
    /// writer and the out-of-process reader cannot drift apart.
    public nonisolated static let mcpServerEnabledKey = "qwave.mcpServer"

    /// When ON, the out-of-process `qwave-mcp` MCP server is permitted to
    /// answer read-only tool calls over this profile's history, bookmarks and
    /// last saved session. Defaults to OFF, and deliberately so: turning it on
    /// lets *any* process that can spawn the binary read the user's browsing
    /// history without a further prompt. Nothing in Qwave exposes that surface
    /// unless the user asks for it.
    public var mcpServerEnabled: Bool {
        get { defaults.object(forKey: Self.mcpServerEnabledKey) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Self.mcpServerEnabledKey) }
    }
}
