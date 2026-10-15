import Foundation

/// Explicit reading preferences are independent of the device's travel region.
@MainActor
public final class ReadingLanguagePreferences {
    public static let shared = ReadingLanguagePreferences()
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var language: String {
        get { defaults.string(forKey: "reading.language") ?? Locale.preferredLanguages.first ?? "en" }
        set { defaults.set(newValue, forKey: "reading.language") }
    }
    public var automatic: Bool {
        get { defaults.object(forKey: "reading.automatic") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "reading.automatic") }
    }
    public var excludedHosts: [String] {
        get { defaults.stringArray(forKey: "reading.excludedHosts") ?? [] }
        set { defaults.set(newValue, forKey: "reading.excludedHosts") }
    }
    public var excludedLanguages: [String] {
        get { defaults.stringArray(forKey: "reading.excludedLanguages") ?? [] }
        set { defaults.set(newValue, forKey: "reading.excludedLanguages") }
    }
    public static func base(_ language: String) -> String {
        language.replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map(String.init)?.lowercased()
            ?? "en"
    }
    public func permits(host: String?, source: String) -> Bool {
        automatic && !excludedHosts.contains(host?.lowercased() ?? "")
            && !excludedLanguages.contains(Self.base(source)) && Self.base(source) != Self.base(language)
    }
    public var acceptLanguage: String {
        let code = language.replacingOccurrences(of: "_", with: "-")
        guard code.range(of: "^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*$", options: .regularExpression) != nil else {
            return "en"
        }
        let base = Self.base(code)
        return code == base ? code : "\(code),\(base);q=0.9"
    }
}
