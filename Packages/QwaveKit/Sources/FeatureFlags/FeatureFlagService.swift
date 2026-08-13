import Foundation
import WebKit
import Combine
import QwaveSupport

/// Surfaces WebKit's experimental/preview feature toggles — the same set
/// Safari Technology Preview exposes — via the `_WKFeature` SPI on
/// `WKPreferences`, discovered at runtime through the ObjC runtime.
///
/// Every SPI touch is `responds(to:)`-guarded: on a WebKit where the SPI is
/// renamed or gone the service degrades to "no features available" and the
/// browser keeps working. This is acceptable for a developer-signed,
/// non-App-Store browser; nothing else in Qwave depends on SPI.
@MainActor
public final class FeatureFlagService: ObservableObject {
    @Published public private(set) var features: [WebFeature] = []
    public private(set) var isSPIAvailable = false

    private let defaults: UserDefaults
    private let safety: FeatureFlagSafety
    private var overrides: [String: Bool] {
        didSet {
            defaults.set(overrides, forKey: Self.overridesKey)
        }
    }

    static let overridesKey = "qwave.featureFlagOverrides"

    private static let featuresSelector = NSSelectorFromString("_features")
    private static let setEnabledSelector = NSSelectorFromString("_setEnabled:forFeature:")
    private static let isEnabledSelector = NSSelectorFromString("_isEnabledForFeature:")

    public init(defaults: UserDefaults = .standard, safety: FeatureFlagSafety = FeatureFlagSafety()) {
        self.defaults = defaults
        self.safety = safety
        self.overrides = (defaults.dictionary(forKey: Self.overridesKey) as? [String: Bool]) ?? [:]
        loadFeatures()
    }

    // MARK: - Discovery

    public func loadFeatures() {
        guard let rawFeatures = Self.copyRawFeatures(), !rawFeatures.isEmpty else {
            isSPIAvailable = false
            features = []
            return
        }

        let probe = WKPreferences()
        let parsed = rawFeatures.compactMap { raw -> WebFeature? in
            guard
                let key =
                    (Self.string(from: raw, key: "key") ?? Self.string(from: raw, key: "keyName")
                        ?? Self.string(from: raw, key: "identifier")),
                !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }

            let rawName = Self.string(from: raw, key: "name") ?? Self.string(from: raw, key: "displayName")
            let name = (rawName != nil && !rawName!.isEmpty) ? rawName! : key

            let defaultValue = Self.bool(from: raw, key: "defaultValue") ?? false
            let status = WebFeature.Status(rawStatus: Self.int(from: raw, key: "status") ?? -1)
            let current = overrides[key] ?? Self.isEnabled(raw, on: probe) ?? defaultValue
            return WebFeature(
                key: key,
                name: name,
                details: Self.string(from: raw, key: "details"),
                status: status,
                defaultValue: defaultValue,
                isEnabled: current
            )
        }
        .sorted { ($0.name.lowercased(), $0.key) < ($1.name.lowercased(), $1.key) }

        isSPIAvailable = !parsed.isEmpty
        features = parsed
        QwaveLog.features.info("Discovered \(self.features.count) WebKit features via SPI")
    }

    /// Raw `_WKFeature` objects, or nil when the SPI is unavailable.
    private static func copyRawFeatures() -> [NSObject]? {
        let cls: AnyObject = WKPreferences.self
        if cls.responds(to: featuresSelector),
            let result = cls.perform(featuresSelector)?.takeUnretainedValue() as? [NSObject]
        {
            return result
        }
        let instance = WKPreferences()
        if instance.responds(to: featuresSelector),
            let result = instance.perform(featuresSelector)?.takeUnretainedValue() as? [NSObject]
        {
            return result
        }
        return nil
    }

    // MARK: - Toggling

    public func setEnabled(_ enabled: Bool, forKey key: String) {
        guard !safety.isDenied(key: key) else {
            QwaveLog.features.warning("Refusing to toggle denylisted feature \(key, privacy: .public)")
            return
        }
        overrides[key] = enabled
        if let index = features.firstIndex(where: { $0.key == key }) {
            features[index].isEnabled = enabled
        }
    }

    public func resetAll() {
        overrides = [:]
        loadFeatures()
    }

    public var overriddenCount: Int { overrides.count }

    /// Applies the user's overrides to a fresh `WKPreferences` — called by
    /// `WebViewFactory` for every new configuration.
    public func apply(to preferences: WKPreferences) {
        guard isSPIAvailable, !overrides.isEmpty else { return }
        guard let rawFeatures = Self.copyRawFeatures() else { return }
        guard preferences.responds(to: Self.setEnabledSelector) else { return }

        typealias SetEnabledIMP = @convention(c) (NSObject, Selector, ObjCBool, NSObject) -> Void
        guard let method = class_getMethodImplementation(type(of: preferences), Self.setEnabledSelector) else {
            return
        }
        let setEnabled = unsafeBitCast(method, to: SetEnabledIMP.self)

        for raw in rawFeatures {
            guard let key = Self.string(from: raw, key: "key"),
                let value = overrides[key],
                !safety.isDenied(key: key)
            else { continue }
            setEnabled(preferences, Self.setEnabledSelector, ObjCBool(value), raw)
        }
    }

    private static func isEnabled(_ feature: NSObject, on preferences: WKPreferences) -> Bool? {
        guard preferences.responds(to: isEnabledSelector) else { return nil }
        typealias IsEnabledIMP = @convention(c) (NSObject, Selector, NSObject) -> ObjCBool
        guard let method = class_getMethodImplementation(type(of: preferences), isEnabledSelector) else {
            return nil
        }
        let isEnabled = unsafeBitCast(method, to: IsEnabledIMP.self)
        return isEnabled(preferences, isEnabledSelector, feature).boolValue
    }

    // MARK: - Guarded KVC

    private static func string(from object: NSObject, key: String) -> String? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return object.value(forKey: key) as? String
    }

    private static func bool(from object: NSObject, key: String) -> Bool? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return (object.value(forKey: key) as? NSNumber)?.boolValue
    }

    private static func int(from object: NSObject, key: String) -> Int? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return (object.value(forKey: key) as? NSNumber)?.intValue
    }
}
