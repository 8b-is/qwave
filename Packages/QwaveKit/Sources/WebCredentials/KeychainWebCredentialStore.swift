import Foundation
import os
import Security

/// Keychain-backed website-login store.
///
/// Credentials are `kSecClassInternetPassword` items keyed by server (domain)
/// and account (username), marked **synchronizable** so they ride iCloud
/// Keychain when the user has it enabled — the same mechanism Safari uses,
/// giving Qwave logins cross-device sync for free without Qwave running any
/// sync service of its own (nothing phones home; iCloud is the transport).
///
/// This is a separate keychain *class and account space* from
/// `DeviceKeyManager`'s VPN key material (a non-synchronizable
/// `kSecClassGenericPassword` item). The two never share an item and are never
/// interchanged, even when they ride the same access group.
public struct KeychainWebCredentialStore: WebCredentialStore {
    /// This module is deliberately dependency-free within QwaveKit (Foundation +
    /// Security only, see Package.swift), so this logs directly through the
    /// system `os.Logger` rather than pulling in `QwaveSupport`'s `QwaveLog`.
    /// Subsystem matches the one `CredentialProviderViewController` uses.
    private static let log = Logger(subsystem: "is.8b.qwave.autofill", category: "keychain-web-credential-store")

    /// Shared keychain access group. When the app is signed with a team id this
    /// is `$(TeamIdentifierPrefix)is.8b.qwave.shared`, letting the AutoFill
    /// extension read what the browser saved. Pass `nil` in unsigned dev builds.
    public let accessGroup: String?

    public init(accessGroup: String? = nil) {
        self.accessGroup = accessGroup
    }

    private func baseQuery(domain: String, username: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: WebCredentialMatching.normalize(domain),
            // Synchronizable items are a distinct keychain namespace; queries
            // must opt in explicitly or they will not see iCloud-synced items.
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        if let username {
            query[kSecAttrAccount as String] = username
        }
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    public func credentials(forDomain domain: String) throws -> [WebCredential] {
        var query = baseQuery(domain: domain)
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let items = result as? [[String: Any]] else {
                throw WebCredentialError.malformedItem
            }
            let normalizedDomain = WebCredentialMatching.normalize(domain)
            // `compactMap`, not `map`: one keychain item that fails to decode
            // (missing account/value, or a password blob that isn't valid
            // UTF-8 — plausible for items another tool wrote into this shared
            // access group) must not discard every *other* healthy credential
            // for the domain. Skip and log the bad item; keep the rest.
            return items.compactMap { item in
                guard
                    let account = item[kSecAttrAccount as String] as? String,
                    let data = item[kSecValueData as String] as? Data,
                    let password = String(data: data, encoding: .utf8)
                else {
                    Self.log.error(
                        "skipping malformed keychain item for domain \(normalizedDomain, privacy: .private)"
                    )
                    return nil
                }
                return WebCredential(domain: normalizedDomain, username: account, password: password)
            }
        case errSecItemNotFound:
            return []
        default:
            throw WebCredentialError.unexpectedStatus(status)
        }
    }

    public func save(_ credential: WebCredential) throws {
        guard let data = credential.password.data(using: .utf8) else {
            throw WebCredentialError.malformedItem
        }
        var attributes = baseQuery(domain: credential.domain, username: credential.username)
        // Store synchronizable=true (baseQuery uses `Any`, which is only valid
        // for queries — an add must pin a concrete boolean).
        attributes[kSecAttrSynchronizable as String] = kCFBooleanTrue as Any
        attributes[kSecValueData as String] = data

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(
                baseQuery(domain: credential.domain, username: credential.username) as CFDictionary,
                update as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw WebCredentialError.unexpectedStatus(updateStatus)
            }
        } else if status != errSecSuccess {
            throw WebCredentialError.unexpectedStatus(status)
        }
    }

    public func remove(domain: String, username: String) throws {
        let status = SecItemDelete(baseQuery(domain: domain, username: username) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw WebCredentialError.unexpectedStatus(status)
        }
    }
}
