import CryptoKit
import Foundation
import QwaveSupport

public enum MemoryCipherError: Error, Equatable {
    case missingKey
    case malformedBox
    case authenticationFailed
}

/// AES-GCM for payload bytes. The 79-byte wave frame stays in the clear
/// (it carries no document text); only title/url/body are sealed.
public enum MemoryCipher {
    public static let keyAccount = "memorywave.master-key"

    public static func loadOrCreateKey(in secrets: SecretStore) throws -> SymmetricKey {
        if let existing = try secrets.secret(for: keyAccount), existing.count == 32 {
            return SymmetricKey(data: existing)
        }
        let key = SymmetricKey(size: .bits256)
        try secrets.setSecret(Data(key), for: keyAccount)
        return key
    }

    public static func seal(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let combined = box.combined else { throw MemoryCipherError.malformedBox }
        return combined
    }

    public static func open(_ box: Data, key: SymmetricKey) throws -> Data {
        guard box.count > 12 + 16 else { throw MemoryCipherError.malformedBox }
        do {
            return try AES.GCM.open(try AES.GCM.SealedBox(combined: box), using: key)
        } catch {
            throw MemoryCipherError.authenticationFailed
        }
    }

    public static func hostTag(_ host: String, key: SymmetricKey) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(host.utf8), using: key)
        return Data(mac)
    }
}

private extension Data {
    init(_ key: SymmetricKey) {
        self = key.withUnsafeBytes { Data($0) }
    }
}
