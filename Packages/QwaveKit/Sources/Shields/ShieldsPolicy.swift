import Foundation
import Combine
import URLIdentity

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
            let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        {
            self.defaultAdsBlocked = snapshot.defaultAdsBlocked
            self.defaultHTTPSFirst = snapshot.defaultHTTPSFirst
            // Re-key persisted overrides: pre-v0.3.0 keys used Foundation's
            // reading of the host (e.g. unbracketed IPv6), which no longer
            // matches the WHATWG-canonical lookups.
            self.overrides = Dictionary(
                snapshot.overrides.map { (Self.normalize($0.key), $0.value) },
                uniquingKeysWith: { first, _ in first }
            )
        } else {
            self.defaultAdsBlocked = defaultAdsBlocked
            self.defaultHTTPSFirst = defaultHTTPSFirst
            self.overrides = [:]
        }
    }

    public func resolvedPolicy(forHost host: String?) -> ResolvedShieldsPolicy {
        // Skip the WebURL host parse in normalize() when there are no per-site
        // overrides (the common case) — an empty dict can only miss.
        let override = overrides.isEmpty ? nil : host.flatMap { overrides[Self.normalize($0)] }
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

    /// Hosts are matched on their WHATWG-canonical form (punycode, lowercase,
    /// decoded percent-escapes, normalized IP literals — the identity WebKit
    /// loads) minus a leading "www.". Bare IPv6 literals (Foundation's
    /// bracket-stripped form, also the pre-v0.3.0 persisted form) are
    /// re-bracketed so they land on the same canonical "[addr]" key. Strings
    /// that don't parse as a host fall back to plain lowercasing so garbage
    /// keys stay inert.
    static func normalize(_ host: String) -> String {
        let candidate = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let canonical = CanonicalHost.host(ofURLString: "https://\(candidate)/") ?? host.lowercased()
        return canonical.hasPrefix("www.") ? String(canonical.dropFirst(4)) : canonical
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
