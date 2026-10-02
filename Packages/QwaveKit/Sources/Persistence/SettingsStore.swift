import Foundation

/// The search engines Qwave offers.
///
/// Deliberately short: Ecosia (the default — trees, privacy, green hosting)
/// and DuckDuckGo are the only engines with a vetted, keyless autocomplete
/// endpoint, and Qwave will not ship an engine whose remote suggestions it
/// cannot fetch honestly. Adding an engine means vetting its suggestion
/// endpoint, allowlisting it in both Category-A lists, and wiring a provider.
public enum SearchEngine: String, CaseIterable, Codable, Identifiable, Sendable {
    case ecosia
    case duckduckgo

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ecosia: return "Ecosia"
        case .duckduckgo: return "DuckDuckGo"
        }
    }

    public func searchURL(for query: String) -> URL? {
        guard let escaped = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        switch self {
        case .ecosia: return URL(string: "https://www.ecosia.org/search?q=\(escaped)")
        case .duckduckgo: return URL(string: "https://duckduckgo.com/?q=\(escaped)")
        }
    }
}

/// How Qwave's chrome and web content are presented.
///
/// `.system` follows macOS's appearance. A forced `.light` / `.dark` sets the
/// app chrome explicitly AND hints the color scheme to pages: WebViewFactory
/// injects a `color-scheme` declaration at document start, so UA-rendered
/// surfaces (form controls, scrollbars) and sites that honor the property
/// follow the choice. Pages using `prefers-color-scheme` media queries still
/// see the OS value — WebKit exposes no public way to force it, and Qwave
/// will not reach for SPI to fake one.
public enum ThemeMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
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
        static let themeMode = "qwave.themeMode"
        static let defaultZoom = "qwave.defaultZoom"
        static let reduceMotion = "qwave.reduceMotion"
    }

    /// The smallest and largest page zoom Qwave will apply or persist.
    /// Mirrors the ⌘+/⌘- bounds in BrowserWindowController so the setting
    /// and the menu can never drift apart.
    public static let zoomBounds: ClosedRange<Double> = 0.4...3.0

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var searchEngine: SearchEngine {
        get {
            defaults.string(forKey: Key.searchEngine).flatMap(SearchEngine.init(rawValue:)) ?? .ecosia
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

    /// How the app chrome (and, via the color-scheme hint, web content) is
    /// presented. Defaults to `.system`.
    public var themeMode: ThemeMode {
        get {
            defaults.string(forKey: Key.themeMode).flatMap(ThemeMode.init(rawValue:)) ?? .system
        }
        set { defaults.set(newValue.rawValue, forKey: Key.themeMode) }
    }

    /// The page zoom applied to every new tab (and restored hibernate
    /// rebuilds). ⌘+/⌘-/⌘0 still change the zoom per tab afterwards; this is
    /// the starting value. Out-of-range values clamp to the nearest bound of
    /// ``SettingsStore/zoomBounds`` rather than resetting, so a stray value
    /// in the defaults domain degrades to the closest sane zoom. Defaults to
    /// 1.0 (actual size).
    public var defaultPageZoom: Double {
        get {
            // `double(forKey:)` returns 0.0 for an unset key, which would read
            // as the floor; an unset key means the default, 1.0.
            guard let value = defaults.object(forKey: Key.defaultZoom) as? NSNumber else {
                return 1.0
            }
            return clampedZoom(value.doubleValue)
        }
        set { defaults.set(clampedZoom(newValue), forKey: Key.defaultZoom) }
    }

    private func clampedZoom(_ value: Double) -> Double {
        min(max(value, SettingsStore.zoomBounds.lowerBound), SettingsStore.zoomBounds.upperBound)
    }

    /// When ON, every page gets a document-start style that collapses CSS
    /// animations, transitions, and smooth scrolling — the "force reduced
    /// motion" behaviour, independent of the OS-wide setting. Defaults to
    /// OFF. Applies to tabs opened after the change.
    public var reduceMotionEnabled: Bool {
        get { defaults.object(forKey: Key.reduceMotion) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.reduceMotion) }
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
