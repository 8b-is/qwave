import Foundation

/// Origin binding for a WebAuthn ceremony: may the frame that asked actually
/// claim the `rpId` it asked for?
///
/// WebAuthn only lets a caller pick an `rpId` that "is a registrable domain
/// suffix of, or is equal to" the caller's effective domain (§5.1.3 / §5.1.4).
/// Skipping that check lets any frame — including a cross-origin ad iframe —
/// drive a real platform passkey ceremony for an arbitrary relying party.
///
/// Pure on purpose: no WebKit, no URL parser, no keychain, so the rule itself is
/// unit-testable the way the rest of this module's value types are. Callers hand
/// in *canonical* hosts — WebKit's own `WKFrameInfo.securityOrigin.host` for the
/// frame, and the page-supplied `rpId` run through `URLIdentity.CanonicalHost` —
/// because this type deliberately does no URL parsing of its own.
public enum WebAuthnOriginPolicy {
    /// The `rpID` a ceremony for `originHost` may run with — normalized — or nil
    /// when the origin may not claim it.
    ///
    /// Returning the value rather than a bool is deliberate: normalization
    /// (case, trailing root dot) happens *inside* the decision, so a caller that
    /// re-used its own input string would hand the authenticator something other
    /// than what was authorized. `example.com.` is authorized as, and comes back
    /// as, `example.com`.
    ///
    /// `rpID` is authorized when it is equal to, or a registrable-domain suffix
    /// of, `originHost`. The suffix must break on a label boundary:
    /// `login.example.com` is covered by `example.com`, while `evil-example.com`
    /// is not.
    ///
    /// Known limitation: with no public-suffix list in the tree, a suffix that
    /// is itself a public suffix (`co.uk` claimed from `evil.co.uk`) cannot be
    /// rejected. Single-label suffixes (`com`) are refused outright, which
    /// covers the common shape; a real PSL is the follow-up — the same one
    /// ``WebCredentialMatching`` already defers.
    public static func authorizedRPID(_ rpID: String, forOriginHost originHost: String) -> String? {
        let rp = normalizeHost(rpID)
        let origin = normalizeHost(originHost)
        guard !rp.isEmpty, !origin.isEmpty else { return nil }
        // Same effective domain: always allowed, including single-label intranet
        // hosts and IP literals, where "registrable suffix" has no meaning.
        if rp == origin { return rp }
        // An IP-literal origin has no registrable domain, so nothing but exact
        // equality may authorise it — otherwise "1.2.3.4" would hand rpId "3.4"
        // a ceremony.
        guard !isIPLiteral(origin) else { return nil }
        // A single-label rpId is never a site's registrable domain; refusing it
        // stops a page at "example.com" from claiming the whole "com" suffix.
        guard rp.contains(".") else { return nil }
        // The dot is what forces the match onto a label boundary.
        return origin.hasSuffix("." + rp) ? rp : nil
    }

    /// True when ``authorizedRPID(_:forOriginHost:)`` would permit the ceremony.
    /// Decision only — a caller that goes on to *run* the ceremony must use the
    /// rpID that function returns, not its own input.
    public static func rpIDIsAuthorized(_ rpID: String, forOriginHost originHost: String) -> Bool {
        authorizedRPID(rpID, forOriginHost: originHost) != nil
    }

    /// Lowercase and drop one trailing root-label dot (`example.com.` is the
    /// same host as `example.com`). Inputs are already canonical; this only
    /// makes the comparison total.
    private static func normalizeHost(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasSuffix(".") { value.removeLast() }
        return value
    }

    /// WHATWG serialises IPv6 hosts in brackets; an IPv4 literal is all-numeric
    /// labels.
    private static func isIPLiteral(_ host: String) -> Bool {
        if host.hasPrefix("[") { return true }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            !label.isEmpty && label.allSatisfy { $0.isASCII && $0.isNumber }
        }
    }
}
