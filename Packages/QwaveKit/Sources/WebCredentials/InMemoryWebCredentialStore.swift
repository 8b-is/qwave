import Foundation

/// Thread-safe in-memory store for tests and keychain-less environments.
public final class InMemoryWebCredentialStore: WebCredentialStore, @unchecked Sendable {
    private struct Key: Hashable {
        let domain: String
        let username: String
    }

    private var storage: [Key: WebCredential] = [:]
    private let lock = NSLock()

    public init() {}

    public func credentials(forDomain domain: String) throws -> [WebCredential] {
        lock.lock()
        defer { lock.unlock() }
        return storage.values
            .filter { WebCredentialMatching.domainMatches(stored: $0.domain, requested: domain) }
            .sorted { $0.username < $1.username }
    }

    public func save(_ credential: WebCredential) throws {
        lock.lock()
        defer { lock.unlock() }
        let key = Key(
            domain: WebCredentialMatching.normalize(credential.domain),
            username: credential.username
        )
        storage[key] = WebCredential(
            domain: WebCredentialMatching.normalize(credential.domain),
            username: credential.username,
            password: credential.password
        )
    }

    public func remove(domain: String, username: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: Key(domain: WebCredentialMatching.normalize(domain), username: username))
    }
}
