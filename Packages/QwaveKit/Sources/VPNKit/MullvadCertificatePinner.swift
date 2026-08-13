import Foundation
import CryptoKit
import Security

/// Pins the `api.mullvad.net` TLS chain to the ISRG roots. See docs/PINNING.md
/// for the full rotation design and threat model. In short: the leaf is a
/// 90-day Let's Encrypt cert and the intermediate rotates, so only the stable
/// ISRG **root** is a viable pin. The pin is enforced *in addition to* system
/// trust, and it fails closed (no fallback to system-only trust).
public enum MullvadCertificatePinner {
    /// SPKI SHA-256 (base64) of the ISRG roots. Both are pinned so Let's
    /// Encrypt may serve either an RSA (X1) or ECDSA (X2) chain. Recompute
    /// via the openssl pipeline in docs/PINNING.md.
    public static let pinnedRootSPKISHA256: Set<String> = [
        "C5+lpZ7tcVwmwQIMcRtPbsQtWLABXhQzejna0wHFr8M=",  // ISRG Root X1 (RSA)
        "diGVwiVYbubAI3RW4hB9xU8e/CH2GnkuvVFZE8zmgzI=",  // ISRG Root X2 (ECDSA)
    ]

    /// The host this pin applies to. Any other host is left to system trust.
    public static let pinnedHost = "api.mullvad.net"

    /// SPKI SHA-256, base64 — the standard pin digest (DER of the
    /// SubjectPublicKeyInfo, hashed).
    static func spkiPin(for certificate: SecCertificate) -> String? {
        guard let publicKey = SecCertificateCopyKey(certificate),
            let der = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?
        else { return nil }
        // SecKeyCopyExternalRepresentation returns the raw key, not the full
        // SPKI DER; the ASN.1 SPKI header must be prepended to match the
        // openssl `pkey -pubin -outform der` output that the pins were
        // computed from. Header depends on the key algorithm.
        guard let spki = Self.spkiDER(publicKey: publicKey, rawKey: der) else { return nil }
        let digest = SHA256.hash(data: spki)
        return Data(digest).base64EncodedString()
    }

    /// Prepends the algorithm-specific ASN.1 SubjectPublicKeyInfo header to a
    /// raw key so the digest matches a standard SPKI pin. Covers the two key
    /// types ISRG roots use: RSA-4096 (X1) and P-384 (X2).
    private static func spkiDER(publicKey: SecKey, rawKey: Data) -> Data? {
        guard let attrs = SecKeyCopyAttributes(publicKey) as? [CFString: Any],
            let keyType = attrs[kSecAttrKeyType] as? String,
            let keySize = attrs[kSecAttrKeySizeInBits] as? Int
        else { return nil }

        let header: [UInt8]
        if keyType == (kSecAttrKeyTypeRSA as String), keySize == 4096 {
            header = [
                0x30, 0x82, 0x02, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86,
                0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x02, 0x0f, 0x00,
            ]
        } else if keyType == (kSecAttrKeyTypeECSECPrimeRandom as String), keySize == 384 {
            header = [
                0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02,
                0x01, 0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x22, 0x03, 0x62, 0x00,
            ]
        } else {
            return nil
        }
        return Data(header) + rawKey
    }

    /// Validates a server trust for `host`: system trust must pass AND, for
    /// the pinned host, some certificate in the chain must be a pinned ISRG
    /// root. Hosts other than the pinned host pass on system trust alone.
    public static func validate(serverTrust: SecTrust, host: String) -> Bool {
        // 1. System trust first — hostname, expiry, revocation, chain.
        var error: CFError?
        guard SecTrustEvaluateWithError(serverTrust, &error) else { return false }

        // 2. Only the Mullvad API is pinned.
        guard host == pinnedHost else { return true }

        // 3. Chain must anchor to a pinned ISRG root.
        let count = SecTrustGetCertificateCount(serverTrust)
        guard count > 0 else { return false }
        let chain = (SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate]) ?? []
        for certificate in chain {
            if let pin = spkiPin(for: certificate), pinnedRootSPKISHA256.contains(pin) {
                return true
            }
        }
        return false
    }
}

/// URLSessionDelegate that applies `MullvadCertificatePinner` to server-trust
/// challenges. Keeping the pin in a delegate preserves URLSession as the
/// transport (so tunnel-aware system routing is unchanged) — the pin only
/// decides accept/reject, it does not open its own socket.
public final class MullvadPinningDelegate: NSObject, URLSessionDelegate, Sendable {
    public override init() { super.init() }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let serverTrust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if MullvadCertificatePinner.validate(serverTrust: serverTrust, host: challenge.protectionSpace.host) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

extension URLSession {
    /// A URLSession that pins `api.mullvad.net` to the ISRG roots. Used by the
    /// Mullvad control-API client. `URLSession.shared` cannot carry a
    /// delegate, so the app builds this and injects it.
    public static func mullvadPinned() -> URLSession {
        URLSession(
            configuration: .ephemeral,
            delegate: MullvadPinningDelegate(),
            delegateQueue: nil
        )
    }
}
