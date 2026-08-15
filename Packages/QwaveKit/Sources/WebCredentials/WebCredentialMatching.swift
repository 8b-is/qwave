import Foundation

/// Pure domain-matching rules shared by the store and the AutoFill extension,
/// factored out so they can be unit-tested without a keychain.
public enum WebCredentialMatching {
    /// Normalise a domain for storage/lookup: lowercase, strip a leading
    /// `www.`, strip a scheme, a path, and any port. AutoFill hands the
    /// extension a service identifier that may be a bare host or a full URL, so
    /// both callers normalise through here before comparing.
    public static func normalize(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let schemeRange = value.range(of: "://") {
            value = String(value[schemeRange.upperBound...])
        }
        if let slash = value.firstIndex(of: "/") {
            value = String(value[..<slash])
        }
        if let colon = value.firstIndex(of: ":") {
            value = String(value[..<colon])
        }
        if value.hasPrefix("www.") {
            value = String(value.dropFirst(4))
        }
        return value
    }

    /// A stored credential matches a requested identifier when their normalised
    /// registrable-ish forms are equal. This is intentionally exact-host (after
    /// `www.` stripping) rather than a public-suffix eTLD+1 match: broadening it
    /// is a follow-up that needs a public-suffix list to avoid cross-site leaks.
    public static func domainMatches(stored: String, requested: String) -> Bool {
        let s = normalize(stored)
        let r = normalize(requested)
        guard !s.isEmpty, !r.isEmpty else { return false }
        return s == r
    }
}
