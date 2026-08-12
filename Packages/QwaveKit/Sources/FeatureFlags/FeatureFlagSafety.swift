import Foundation

/// Features Qwave refuses to toggle from the UI because flipping them is known
/// to break basic browsing or the browser's own integration assumptions.
public struct FeatureFlagSafety: Sendable {
    public let deniedKeys: Set<String>
    public let deniedPrefixes: [String]

    public init(
        deniedKeys: Set<String> = [
            // Process/sandbox topology — Qwave's per-container isolation
            // assumes WebKit's default process model.
            "ProcessSwapOnCrossSiteNavigationEnabled",
            "SiteIsolationEnabled",
        ],
        deniedPrefixes: [String] = []
    ) {
        self.deniedKeys = deniedKeys
        self.deniedPrefixes = deniedPrefixes
    }

    public func isDenied(key: String) -> Bool {
        if deniedKeys.contains(key) { return true }
        return deniedPrefixes.contains { key.hasPrefix($0) }
    }
}
