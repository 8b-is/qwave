import Foundation
import Combine

/// Per-site override of the global shield defaults. `nil` means "inherit".
public struct SitePolicy: Codable, Equatable {
    public var adsBlocked: Bool?
    public var httpsFirst: Bool?
    public var jsEnabled: Bool?

    public init(adsBlocked: Bool? = nil, httpsFirst: Bool? = nil, jsEnabled: Bool? = nil) {
        self.adsBlocked = adsBlocked
        self.httpsFirst = httpsFirst
        self.jsEnabled = jsEnabled
    }

    public var isEmpty: Bool {
        adsBlocked == nil && httpsFirst == nil && jsEnabled == nil
    }
}

/// Effective policy for one host after merging defaults and overrides.
public struct ResolvedShieldsPolicy: Equatable {
    public var adsBlocked: Bool
    public var httpsFirst: Bool
    public var jsEnabled: Bool

    public init(adsBlocked: Bool, httpsFirst: Bool, jsEnabled: Bool) {
        self.adsBlocked = adsBlocked
        self.httpsFirst = httpsFirst
        self.jsEnabled = jsEnabled
    }
}

/// Global shield defaults plus persisted per-host overrides — the model behind
/// the Brave-style shields popover.
@MainActor
public final class ShieldsPolicy: ObservableObject {
    @Published public var defaultAdsBlocked: Bool {
        didSet { save() }
    }
    @Published public var defaultHTTPSFirst: Bool {
        didSet { save() }
    }
    @Published public private(set) var overrides: [String: SitePolicy]

    private let fileURL: URL?

    private struct Snapshot: Codable {
        var defaultAdsBlocked: Bool
        var defaultHTTPSFirst: Bool
        var overrides: [String: SitePolicy]
    }

    /// Pass `directory: nil` for a non-persisted instance (tests).
    public init(directory: URL?, defaultAdsBlocked: Bool = true, defaultHTTPSFirst: Bool = true) {
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.fileURL = directory.appendingPathComponent("shields.json")
        } else {
            self.fileURL = nil
        }

        if let fileURL = self.fileURL,
           let data = try? Data(contentsOf: fileURL),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            self.defaultAdsBlocked = snapshot.defaultAdsBlocked
            self.defaultHTTPSFirst = snapshot.defaultHTTPSFirst
            self.overrides = snapshot.overrides
        } else {
            self.defaultAdsBlocked = defaultAdsBlocked
            self.defaultHTTPSFirst = defaultHTTPSFirst
            self.overrides = [:]
        }
    }

    public func resolvedPolicy(forHost host: String?) -> ResolvedShieldsPolicy {
        let override = host.flatMap { overrides[Self.normalize($0)] }
        return ResolvedShieldsPolicy(
            adsBlocked: override?.adsBlocked ?? defaultAdsBlocked,
            httpsFirst: override?.httpsFirst ?? defaultHTTPSFirst,
            jsEnabled: override?.jsEnabled ?? true
        )
    }

    public func setOverride(_ policy: SitePolicy, forHost host: String) {
        let key = Self.normalize(host)
        if policy.isEmpty {
            overrides.removeValue(forKey: key)
        } else {
            overrides[key] = policy
        }
        save()
    }

    public func override(forHost host: String) -> SitePolicy {
        overrides[Self.normalize(host)] ?? SitePolicy()
    }

    public func clearAllOverrides() {
        overrides.removeAll()
        save()
    }

    /// Hosts are matched on their registrable form minus a leading "www.".
    static func normalize(_ host: String) -> String {
        let lowered = host.lowercased()
        return lowered.hasPrefix("www.") ? String(lowered.dropFirst(4)) : lowered
    }

    private func save() {
        guard let fileURL else { return }
        let snapshot = Snapshot(
            defaultAdsBlocked: defaultAdsBlocked,
            defaultHTTPSFirst: defaultHTTPSFirst,
            overrides: overrides
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
