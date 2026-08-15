import Foundation

/// A user's saved login for a website. This is *user data* — a third-party
/// website credential — and is deliberately unrelated to the device-identity
/// crypto (DeviceKeyManager / ML-KEM / MemoryCipher) that keys the VPN tunnel.
/// It never rides those code paths and never shares their key material.
public struct WebCredential: Sendable, Equatable {
    /// The web domain the login belongs to, e.g. `example.com`. Used as the
    /// keychain `kSecAttrServer` and matched against the AutoFill service
    /// identifier the system hands the extension.
    public let domain: String
    /// The account / username portion of the login.
    public let username: String
    /// The secret. Lives only in the OS keychain (optionally iCloud-synced);
    /// it is never persisted anywhere in Qwave's own storage.
    public let password: String

    public init(domain: String, username: String, password: String) {
        self.domain = domain
        self.username = username
        self.password = password
    }
}

/// Read/write access to the user's saved website logins.
///
/// Implementations back onto the OS keychain (see ``KeychainWebCredentialStore``)
/// or memory (see ``InMemoryWebCredentialStore`` for tests). The protocol keeps
/// the AutoFill extension and the browser app talking to the *same* storage
/// contract without either importing keychain plumbing directly.
public protocol WebCredentialStore: Sendable {
    /// All stored logins whose domain matches `domain` (see
    /// ``WebCredentialMatching/domainMatches(stored:requested:)`` for the rule).
    func credentials(forDomain domain: String) throws -> [WebCredential]
    /// Insert or update a login (keyed by domain + username).
    func save(_ credential: WebCredential) throws
    /// Remove a login by domain + username. No-op if absent.
    func remove(domain: String, username: String) throws
}

public enum WebCredentialError: Error, Equatable {
    case unexpectedStatus(Int32)
    case malformedItem
}
