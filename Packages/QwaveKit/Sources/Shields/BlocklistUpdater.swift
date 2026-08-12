import Foundation

/// Seam for a future remote blocklist pipeline (fetch upstream EasyList,
/// convert to WKContentRuleList syntax, recompile). Stage A ships only the
/// curated built-in list; the director consumes whatever the compiler serves,
/// so an updater can slot in without touching call sites.
public protocol BlocklistUpdating: Sendable {
    /// Returns fresh content-blocker JSON, or nil when the built-in list is
    /// already current.
    func fetchUpdatedBlocklistJSON() async throws -> String?
}

public struct NoopBlocklistUpdater: BlocklistUpdating {
    public init() {}

    public func fetchUpdatedBlocklistJSON() async throws -> String? {
        nil
    }
}
