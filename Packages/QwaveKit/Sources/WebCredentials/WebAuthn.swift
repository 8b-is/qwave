import Foundation

/// Base64URL (RFC 4648 §5, no padding) — the wire encoding WebAuthn uses for
/// challenges, credential ids, and raw signature blobs when they cross the
/// JavaScript boundary. Pure and testable; drives the app-side passkey driver.
public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        var s = data.base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-")
        s = s.replacingOccurrences(of: "/", with: "_")
        s = s.replacingOccurrences(of: "=", with: "")
        return s
    }

    public static func decode(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+")
        s = s.replacingOccurrences(of: "_", with: "/")
        // Restore removed padding to a multiple of 4.
        let remainder = s.count % 4
        if remainder > 0 {
            s.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: s)
    }
}

/// A parsed `navigator.credentials.get()` request, decoded from what a web page
/// hands the browser. Value type on purpose: it carries no framework objects and
/// is fully unit-testable. The app-side driver turns it into an
/// `ASAuthorizationPlatformPublicKeyCredentialProvider` assertion request.
public struct PasskeyAssertionRequest: Sendable, Equatable {
    /// Relying-party identifier — the site's registrable domain (WebAuthn `rpId`).
    public let relyingPartyIdentifier: String
    /// The server-issued challenge (decoded from base64url).
    public let challenge: Data
    /// Optional allow-list of credential ids the RP will accept (decoded).
    public let allowedCredentialIDs: [Data]

    public init(relyingPartyIdentifier: String, challenge: Data, allowedCredentialIDs: [Data] = []) {
        self.relyingPartyIdentifier = relyingPartyIdentifier
        self.challenge = challenge
        self.allowedCredentialIDs = allowedCredentialIDs
    }

    /// Build from the JSON-ish payload a page bridge delivers. Expects
    /// base64url-encoded `challenge` and (optional) `allowCredentials[].id`.
    public init?(json: [String: Any]) {
        guard
            let rpID = json["rpId"] as? String, !rpID.isEmpty,
            let challengeString = json["challenge"] as? String,
            let challenge = Base64URL.decode(challengeString)
        else {
            return nil
        }
        var allowed: [Data] = []
        if let list = json["allowCredentials"] as? [[String: Any]] {
            for entry in list {
                if let idString = entry["id"] as? String, let id = Base64URL.decode(idString) {
                    allowed.append(id)
                }
            }
        }
        self.init(relyingPartyIdentifier: rpID, challenge: challenge, allowedCredentialIDs: allowed)
    }
}

/// A parsed `navigator.credentials.create()` request for a platform passkey.
public struct PasskeyRegistrationRequest: Sendable, Equatable {
    public let relyingPartyIdentifier: String
    public let challenge: Data
    public let userName: String
    public let userID: Data

    public init(relyingPartyIdentifier: String, challenge: Data, userName: String, userID: Data) {
        self.relyingPartyIdentifier = relyingPartyIdentifier
        self.challenge = challenge
        self.userName = userName
        self.userID = userID
    }

    public init?(json: [String: Any]) {
        guard
            let rpID = json["rpId"] as? String, !rpID.isEmpty,
            let challengeString = json["challenge"] as? String,
            let challenge = Base64URL.decode(challengeString),
            let user = json["user"] as? [String: Any],
            let name = user["name"] as? String,
            let idString = user["id"] as? String,
            let userID = Base64URL.decode(idString)
        else {
            return nil
        }
        self.init(relyingPartyIdentifier: rpID, challenge: challenge, userName: name, userID: userID)
    }
}
