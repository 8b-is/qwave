import Foundation
import WebKit
import Combine
import QwaveSupport

/// The state of WebKit's feature-toggle surface on this build.
///
/// Three states, deliberately: "selector absent", "selector present but
/// zero features", and "features available". Conflating the first two made
/// an empty surface masquerade as a missing SPI — the pane told a lie and
/// persisted overrides silently stopped applying.
public enum FeatureSurfaceState: Equatable, Sendable {
    /// No SPI selector responds (class or instance) — surface truly absent.
    case unavailable
    /// Selectors respond but expose zero parseable features.
    case emptySurface
    /// Selectors respond and expose features.
    case available([WebFeature])
}

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
    public private(set) var surfaceState: FeatureSurfaceState = .unavailable

    /// True when the surface is present AND exposes features.
    public var isSPIAvailable: Bool {
        if case .available = surfaceState { return true }
        return false
    }

    private let defaults: UserDefaults
    private let safety: FeatureFlagSafety
    private var overrides: [String: Bool] {
        didSet {
            defaults.set(overrides, forKey: Self.overridesKey)
        }
    }

    static let overridesKey = "qwave.featureFlagOverrides"

    private static let setEnabledSelector = NSSelectorFromString("_setEnabled:forFeature:")
    private static let isEnabledSelector = NSSelectorFromString("_isEnabledForFeature:")

    public init(defaults: UserDefaults = .standard, safety: FeatureFlagSafety = FeatureFlagSafety()) {
        self.defaults = defaults
        self.safety = safety
        self.overrides = (defaults.dictionary(forKey: Self.overridesKey) as? [String: Bool]) ?? [:]
        loadFeatures()
    }

    // MARK: - Discovery

    /// Pure tri-state derivation, unit-testable without WebKit.
    static func surfaceState(found: Bool, parsed: [WebFeature]) -> FeatureSurfaceState {
        if !found { return .unavailable }
        if parsed.isEmpty { return .emptySurface }
        return .available(parsed)
    }

    /// The WebKit framework version, for messages that need to say which
    /// build the surface was read from.
    public static var webKitVersionString: String? {
        Bundle(path: "/System/Library/Frameworks/WebKit.framework")?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    public func loadFeatures() {
        let (found, rawFeatures) = Self.rawFeatures()
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

        surfaceState = Self.surfaceState(found: found, parsed: parsed)
        features = parsed
        switch surfaceState {
        case .unavailable:
            QwaveLog.features.info("WebKit feature SPI unavailable on this build")
        case .emptySurface:
            QwaveLog.features.info("WebKit feature SPI present but exposed zero features")
        case .available:
            QwaveLog.features.info("Discovered \(parsed.count) WebKit features via SPI")
        }
    }

    /// Raw `_WKFeature` objects merged across every guarded selector, plus
    /// whether ANY selector responded. The distinction matters: `found ==
    /// false` means the surface is absent; `found == true` with an empty list
    /// is the `.emptySurface` state. Class-level first, then instance — the
    /// SPI lives at the class level on recent WebKit builds (WebKit 21624:
    /// `_features` responds on `WKPreferences.self` but not on an instance).
    private static func rawFeatures() -> (found: Bool, features: [NSObject]) {
        var found = false
        var seenKeys = Set<String>()
        var merged: [NSObject] = []
        let instance = WKPreferences()
        for selectorName in legacyFeatureSelectors {
            let selector = NSSelectorFromString(selectorName)
            let source: [NSObject]?
            if WKPreferences.self.responds(to: selector),
                let result = (WKPreferences.self as AnyObject).perform(selector)?.takeUnretainedValue()
                    as? [NSObject]
            {
                source = result
            } else if instance.responds(to: selector),
                let result = instance.perform(selector)?.takeUnretainedValue() as? [NSObject]
            {
                source = result
            } else {
                source = nil
            }
            guard let source else { continue }
            found = true
            for raw in source {
                let key = Self.string(from: raw, key: "key") ?? Self.string(from: raw, key: "keyName") ?? ""
                if !key.isEmpty {
                    if seenKeys.insert(key).inserted { merged.append(raw) }
                } else {
                    merged.append(raw)  // unkeyed objects are filtered downstream
                }
            }
        }
        return (found, merged)
    }

    private static let legacyFeatureSelectors = [
        "_features", "_experimentalFeatures", "_internalDebugFeatures",
    ]

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
        let (_, rawFeatures) = Self.rawFeatures()
        guard !rawFeatures.isEmpty else { return }
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
