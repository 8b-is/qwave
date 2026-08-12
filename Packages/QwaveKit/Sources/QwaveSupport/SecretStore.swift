import Foundation
import Security

/// Abstraction over secret persistence so VPN key material can be unit-tested
/// without touching the real keychain (headless CI has no usable keychain).
public protocol SecretStore: Sendable {
    func secret(for key: String) throws -> Data?
    func setSecret(_ data: Data, for key: String) throws
    func removeSecret(for key: String) throws
}

public enum SecretStoreError: Error, Equatable {
    case unexpectedStatus(OSStatus)
}

/// Keychain-backed store. `accessGroup` is only honored once the app is signed
/// with a team identifier (see docs/SIGNING.md); pass nil during development.
public struct KeychainSecretStore: SecretStore {
    public let service: String
    public let accessGroup: String?

    public init(service: String = "is.8b.qwave", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func baseQuery(for key: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    public func secret(for key: String) throws -> Data? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw SecretStoreError.unexpectedStatus(status)
        }
    }

    public func setSecret(_ data: Data, for key: String) throws {
        var attributes = baseQuery(for: key)
        attributes[kSecValueData as String] = data

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(baseQuery(for: key) as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw SecretStoreError.unexpectedStatus(updateStatus)
            }
        } else if status != errSecSuccess {
            throw SecretStoreError.unexpectedStatus(status)
        }
    }

    public func removeSecret(for key: String) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.unexpectedStatus(status)
        }
    }
}

/// Thread-safe in-memory store for tests and for environments where the
/// keychain is unavailable.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var storage: [String: Data] = [:]
    private let lock = NSLock()

    public init() {}

    public func secret(for key: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    public func setSecret(_ data: Data, for key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = data
    }

    public func removeSecret(for key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: key)
    }
}
