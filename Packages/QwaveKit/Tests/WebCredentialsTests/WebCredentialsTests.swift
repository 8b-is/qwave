import XCTest

@testable import WebCredentials

final class WebCredentialMatchingTests: XCTestCase {
    func testNormalizeStripsSchemePathPortAndWWW() {
        XCTAssertEqual(WebCredentialMatching.normalize("https://www.Example.com/login?x=1"), "example.com")
        XCTAssertEqual(WebCredentialMatching.normalize("Example.com:8443"), "example.com")
        XCTAssertEqual(WebCredentialMatching.normalize("  www.example.com  "), "example.com")
        XCTAssertEqual(WebCredentialMatching.normalize("sub.example.com"), "sub.example.com")
    }

    func testDomainMatchesIsExactHostAfterNormalization() {
        XCTAssertTrue(WebCredentialMatching.domainMatches(stored: "example.com", requested: "https://www.example.com/x"))
        XCTAssertFalse(WebCredentialMatching.domainMatches(stored: "example.com", requested: "evil-example.com"))
        // Exact-host: a subdomain is NOT treated as a match (see follow-up note).
        XCTAssertFalse(WebCredentialMatching.domainMatches(stored: "example.com", requested: "sub.example.com"))
        XCTAssertFalse(WebCredentialMatching.domainMatches(stored: "", requested: "example.com"))
    }
}

final class InMemoryWebCredentialStoreTests: XCTestCase {
    func testSaveThenRetrieveByDomain() throws {
        let store = InMemoryWebCredentialStore()
        try store.save(WebCredential(domain: "https://www.example.com", username: "alice", password: "s3cret"))
        let matches = try store.credentials(forDomain: "example.com")
        XCTAssertEqual(matches, [WebCredential(domain: "example.com", username: "alice", password: "s3cret")])
    }

    func testSaveOverwritesSameDomainAndUsername() throws {
        let store = InMemoryWebCredentialStore()
        try store.save(WebCredential(domain: "example.com", username: "alice", password: "old"))
        try store.save(WebCredential(domain: "example.com", username: "alice", password: "new"))
        let matches = try store.credentials(forDomain: "example.com")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.password, "new")
    }

    func testMultipleAccountsSortedByUsername() throws {
        let store = InMemoryWebCredentialStore()
        try store.save(WebCredential(domain: "example.com", username: "bob", password: "b"))
        try store.save(WebCredential(domain: "example.com", username: "alice", password: "a"))
        let matches = try store.credentials(forDomain: "example.com")
        XCTAssertEqual(matches.map(\.username), ["alice", "bob"])
    }

    func testRemove() throws {
        let store = InMemoryWebCredentialStore()
        try store.save(WebCredential(domain: "example.com", username: "alice", password: "x"))
        try store.remove(domain: "www.example.com", username: "alice")
        XCTAssertTrue(try store.credentials(forDomain: "example.com").isEmpty)
    }

    func testNoMatchForDifferentDomain() throws {
        let store = InMemoryWebCredentialStore()
        try store.save(WebCredential(domain: "example.com", username: "alice", password: "x"))
        XCTAssertTrue(try store.credentials(forDomain: "other.com").isEmpty)
    }
}

final class Base64URLTests: XCTestCase {
    func testRoundTrip() {
        let data = Data([0x00, 0xFF, 0x10, 0x3E, 0x7F, 0xAB, 0xCD])
        let encoded = Base64URL.encode(data)
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))
        XCTAssertEqual(Base64URL.decode(encoded), data)
    }

    func testDecodeKnownVector() {
        // "ab-_c" style: verify padding restoration for non-multiple-of-4 input.
        let data = Data([0x69, 0xb7, 0x1d])
        XCTAssertEqual(Base64URL.encode(data), "abcd")
        XCTAssertEqual(Base64URL.decode("abcd"), data)
    }

    func testDecodeInvalidReturnsNil() {
        XCTAssertNil(Base64URL.decode("!!!not base64!!!"))
    }
}

final class PasskeyRequestParsingTests: XCTestCase {
    func testAssertionFromJSON() {
        let challenge = Data([1, 2, 3, 4])
        let credID = Data([9, 9, 9])
        let json: [String: Any] = [
            "rpId": "example.com",
            "challenge": Base64URL.encode(challenge),
            "allowCredentials": [["id": Base64URL.encode(credID), "type": "public-key"]],
        ]
        let request = PasskeyAssertionRequest(json: json)
        XCTAssertEqual(request?.relyingPartyIdentifier, "example.com")
        XCTAssertEqual(request?.challenge, challenge)
        XCTAssertEqual(request?.allowedCredentialIDs, [credID])
    }

    func testAssertionRejectsMissingChallenge() {
        XCTAssertNil(PasskeyAssertionRequest(json: ["rpId": "example.com"]))
    }

    func testAssertionRejectsEmptyRPID() {
        XCTAssertNil(PasskeyAssertionRequest(json: ["rpId": "", "challenge": Base64URL.encode(Data([1]))]))
    }

    func testRegistrationFromJSON() {
        let challenge = Data([5, 6, 7])
        let userID = Data([0xAA, 0xBB])
        let json: [String: Any] = [
            "rpId": "example.com",
            "challenge": Base64URL.encode(challenge),
            "user": ["name": "alice@example.com", "id": Base64URL.encode(userID)],
        ]
        let request = PasskeyRegistrationRequest(json: json)
        XCTAssertEqual(request?.relyingPartyIdentifier, "example.com")
        XCTAssertEqual(request?.userName, "alice@example.com")
        XCTAssertEqual(request?.userID, userID)
        XCTAssertEqual(request?.challenge, challenge)
    }
}
