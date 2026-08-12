import Foundation

/// HTTPS-first navigation state machine (pure logic, unit-tested).
///
/// Main-frame http navigations are rewritten to https. If the https attempt
/// fails with a connection/TLS-class error, the original http URL is allowed
/// once per host for the rest of the session. Persistent opt-out lives in
/// `ShieldsPolicy` (`httpsFirst: false` override), which callers pass in as
/// `policyAllowsUpgrade`.
@MainActor
public final class HTTPSFirstUpgrader {
    public enum Decision: Equatable {
        case allow
        case upgrade(URL)
    }

    /// host → original http URL we upgraded away from
    private var pendingUpgrades: [String: URL] = [:]
    /// hosts where https failed and http is tolerated for this session
    private var sessionFallbackHosts: Set<String> = []

    public init() {}

    /// Error codes that mean "the https side of this host is broken", not
    /// "the network is down".
    static let fallbackErrorCodes: Set<Int> = [
        NSURLErrorSecureConnectionFailed,          // -1200
        NSURLErrorServerCertificateHasBadDate,     // -1201
        NSURLErrorServerCertificateUntrusted,      // -1202
        NSURLErrorServerCertificateHasUnknownRoot, // -1203
        NSURLErrorServerCertificateNotYetValid,    // -1204
        NSURLErrorClientCertificateRejected,       // -1205
        NSURLErrorCannotConnectToHost,             // -1004
        NSURLErrorNetworkConnectionLost,           // -1005
        NSURLErrorTimedOut,                        // -1001
    ]

    public func decision(for url: URL, isMainFrame: Bool, policyAllowsUpgrade: Bool) -> Decision {
        guard isMainFrame,
              policyAllowsUpgrade,
              url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased()
        else {
            return .allow
        }

        // Local and non-dotted hosts (localhost, intranet names, IP literals
        // on private ranges) are overwhelmingly http-only; leave them alone.
        if Self.isLocalOrPlainHost(host) {
            return .allow
        }

        // An explicit non-default port means "I know what I'm connecting to".
        if let port = url.port, port != 80 {
            return .allow
        }

        if sessionFallbackHosts.contains(host) {
            return .allow
        }

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .allow
        }
        components.scheme = "https"
        components.port = nil
        guard let upgraded = components.url else {
            return .allow
        }

        pendingUpgrades[host] = url
        return .upgrade(upgraded)
    }

    /// Called from `didFailProvisionalNavigation`. Returns the http URL to
    /// retry when the failure was an https attempt this upgrader caused and
    /// the error class qualifies for fallback.
    public func fallbackURL(afterFailureOf url: URL?, errorCode: Int) -> URL? {
        guard let url,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              let original = pendingUpgrades[host],
              Self.fallbackErrorCodes.contains(errorCode)
        else {
            return nil
        }
        pendingUpgrades.removeValue(forKey: host)
        sessionFallbackHosts.insert(host)
        return original
    }

    /// Called when a navigation commits successfully, clearing bookkeeping.
    public func noteSuccessfulNavigation(to url: URL?) {
        guard let host = url?.host?.lowercased() else { return }
        pendingUpgrades.removeValue(forKey: host)
    }

    public func isSessionFallbackHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return sessionFallbackHosts.contains(host)
    }

    static func isLocalOrPlainHost(_ host: String) -> Bool {
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]" {
            return true
        }
        if host.hasSuffix(".local") || host.hasSuffix(".localhost") {
            return true
        }
        if !host.contains(".") {
            return true
        }
        // IPv4 literal
        let parts = host.split(separator: ".")
        if parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) {
            return true
        }
        return false
    }
}
