import Foundation
import CryptoKit
import QwaveSupport

/// WireGuard device key lifecycle. The Curve25519 private key lives only in
/// the secret store (keychain in production, shared with the tunnel extension
/// via keychain access group once signed); it never enters providerConfiguration
/// or UserDefaults.
public struct DeviceKeyManager: Sendable {
    public static let privateKeyStorageKey = "vpn.wireguard.privateKey"

    private let secrets: SecretStore

    public init(secrets: SecretStore) {
        self.secrets = secrets
    }

    public func currentPrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey? {
        guard let raw = try secrets.secret(for: Self.privateKeyStorageKey) else { return nil }
        return try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
    }

    @discardableResult
    public func generateAndStore() throws -> Curve25519.KeyAgreement.PrivateKey {
        let key = Curve25519.KeyAgreement.PrivateKey()
        try secrets.setSecret(key.rawRepresentation, for: Self.privateKeyStorageKey)
        return key
    }

    /// Existing key or a fresh one, atomically from the caller's view.
    public func obtainPrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        if let existing = try currentPrivateKey() {
            return existing
        }
        return try generateAndStore()
    }

    public func publicKeyBase64() throws -> String? {
        try currentPrivateKey()?.publicKey.rawRepresentation.base64EncodedString()
    }

    public func deleteKey() throws {
        try secrets.removeSecret(for: Self.privateKeyStorageKey)
    }
}
