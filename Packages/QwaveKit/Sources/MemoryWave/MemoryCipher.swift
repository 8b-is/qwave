import CryptoKit
import Foundation
import QwaveSupport

public enum MemoryCipherError: Error, Equatable {
    case missingKey
    case malformedBox
    case authenticationFailed
    /// A master key is stored but is not 256 bits. Memory is *locked*, not
    /// empty: the stored bytes are left untouched so a repaired keychain
    /// restores every record.
    case malformedKey
}

/// AES-GCM for payload bytes. The 79-byte wave frame stays in the clear
/// (it carries no document text); only title/url/body are sealed.
public enum MemoryCipher {
    public static let keyAccount = "memorywave.master-key"

    /// Loads the master key, generating one *only* when no secret exists at all
    /// (a genuine first run).
    ///
    /// Fails closed on a stored-but-malformed key instead of replacing it:
    /// re-keying would make every existing record permanently undecryptable and
    /// `MemoryStore.decode` drops rows it cannot open, so the memories would
    /// silently vanish. An existing secret is never overwritten here.
    ///
    /// The create branch uses the add-only `addSecret`, so the guarantee does
    /// not rest on the read above having seen the truth. If the read reports
    /// "nothing stored" while an item actually exists — a keychain access-group
    /// change once the app ships signed, an item in a different keychain in the
    /// search list, two first runs racing — the write throws
    /// `SecretStoreError.duplicateItem` and the real key survives. An overwrite
    /// there would be silent and permanent, so it is never attempted.
    public static func loadOrCreateKey(in secrets: SecretStore) throws -> SymmetricKey {
        if let existing = try secrets.secret(for: keyAccount) {
            guard existing.count == 32 else { throw MemoryCipherError.malformedKey }
            return SymmetricKey(data: existing)
        }
        let key = SymmetricKey(size: .bits256)
        try secrets.addSecret(Data(key), for: keyAccount)
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
