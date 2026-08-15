import XCTest

@testable import WebCredentials

/// Records every identity-sync call so tests can assert `CredentialSaver`
/// actually drives both halves of the write path (issue #72: nothing did).
private final class SpyCredentialIdentitySyncing: CredentialIdentitySyncing, @unchecked Sendable {
    private(set) var registered: [WebCredential] = []
    private(set) var removed: [(domain: String, username: String)] = []
    var registerError: Error?
    var removeError: Error?

    func registerIdentity(for credential: WebCredential) async throws {
        if let registerError { throw registerError }
        registered.append(credential)
    }

    func removeIdentity(domain: String, username: String) async throws {
        if let removeError { throw removeError }
        removed.append((domain, username))
    }
}

private enum SpyError: Error, Equatable {
    case boom
}

/// A `@Sendable` closure captured by ``CredentialSaver`` may not close over a
/// mutable local `var` under strict concurrency, so tests that need to
/// observe reported errors funnel them through this box instead.
private final class ErrorBox: @unchecked Sendable {
    private(set) var errors: [Error] = []
    func append(_ error: Error) { errors.append(error) }
}

/// The parser's origin binding and password-field rules have their own file:
/// see `PasswordCaptureTests`.
final class CapturedFormCredentialTests: XCTestCase {
    func testParsesAndNormalizesDomainFromTheFrameOrigin() {
        let json: [String: Any] = [
            "username": "alice",
            "passwords": [["value": "s3cret", "autocomplete": ""]],
        ]
        let captured = CapturedFormCredential(json: json, frameOriginHost: "www.example.com")
        XCTAssertEqual(captured, CapturedFormCredential(domain: "example.com", username: "alice", password: "s3cret"))
    }

    func testRejectsMissingUsername() {
        let json: [String: Any] = ["passwords": [["value": "x", "autocomplete": ""]]]
        XCTAssertNil(CapturedFormCredential(json: json, frameOriginHost: "example.com"))
    }

    func testRejectsEmptyPassword() {
        let json: [String: Any] = ["username": "alice", "passwords": [["value": "", "autocomplete": ""]]]
        XCTAssertNil(CapturedFormCredential(json: json, frameOriginHost: "example.com"))
    }

    func testRejectsUnparsableDomain() {
        let json: [String: Any] = ["username": "alice", "passwords": [["value": "x", "autocomplete": ""]]]
        XCTAssertNil(CapturedFormCredential(json: json, frameOriginHost: ""))
    }

    func testAsWebCredentialCarriesTheParsedFields() {
        let captured = CapturedFormCredential(domain: "example.com", username: "alice", password: "s3cret")
        XCTAssertEqual(
            captured.asWebCredential, WebCredential(domain: "example.com", username: "alice", password: "s3cret"))
    }
}

final class CredentialSaverTests: XCTestCase {
    func testSavePersistsToStoreAndIsRetrievableAfterward() async throws {
        let store = InMemoryWebCredentialStore()
        let identitySync = SpyCredentialIdentitySyncing()
        let saver = CredentialSaver(store: store, identitySync: identitySync)

        let credential = WebCredential(domain: "https://www.example.com", username: "alice", password: "s3cret")
        try await saver.save(credential)

        // Retrievable through the very store the AutoFill extension reads.
        let matches = try store.credentials(forDomain: "example.com")
        XCTAssertEqual(matches, [WebCredential(domain: "example.com", username: "alice", password: "s3cret")])
    }

    func testSaveRegistersTheCredentialIdentity() async throws {
        let store = InMemoryWebCredentialStore()
        let identitySync = SpyCredentialIdentitySyncing()
        let saver = CredentialSaver(store: store, identitySync: identitySync)

        let credential = WebCredential(domain: "example.com", username: "alice", password: "s3cret")
        try await saver.save(credential)

        XCTAssertEqual(identitySync.registered, [credential])
    }

    func testSaveOverwritesAndReRegistersOnUpdate() async throws {
        let store = InMemoryWebCredentialStore()
        let identitySync = SpyCredentialIdentitySyncing()
        let saver = CredentialSaver(store: store, identitySync: identitySync)

        try await saver.save(WebCredential(domain: "example.com", username: "alice", password: "old"))
        try await saver.save(WebCredential(domain: "example.com", username: "alice", password: "new"))

        let matches = try store.credentials(forDomain: "example.com")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.password, "new")
        XCTAssertEqual(identitySync.registered.map(\.password), ["old", "new"])
    }

    func testRemoveDeletesFromStoreAndRemovesTheIdentity() async throws {
        let store = InMemoryWebCredentialStore()
        let identitySync = SpyCredentialIdentitySyncing()
        let saver = CredentialSaver(store: store, identitySync: identitySync)

        try await saver.save(WebCredential(domain: "example.com", username: "alice", password: "x"))
        try await saver.remove(domain: "example.com", username: "alice")

        XCTAssertTrue(try store.credentials(forDomain: "example.com").isEmpty)
        XCTAssertEqual(identitySync.removed.map(\.username), ["alice"])
    }

    /// A save must not silently disappear just because the system's identity
    /// index couldn't be updated — the credential itself is already durably
    /// written by the time identity sync runs.
    func testSaveSucceedsEvenWhenIdentitySyncFails() async throws {
        let store = InMemoryWebCredentialStore()
        let identitySync = SpyCredentialIdentitySyncing()
        identitySync.registerError = SpyError.boom
        let reportedErrors = ErrorBox()
        let saver = CredentialSaver(store: store, identitySync: identitySync) { error in
            reportedErrors.append(error)
        }

        try await saver.save(WebCredential(domain: "example.com", username: "alice", password: "s3cret"))

        let matches = try store.credentials(forDomain: "example.com")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(reportedErrors.errors as? [SpyError], [.boom])
    }

    func testRemoveSucceedsEvenWhenIdentitySyncFails() async throws {
        let store = InMemoryWebCredentialStore()
        let identitySync = SpyCredentialIdentitySyncing()
        identitySync.removeError = SpyError.boom
        let reportedErrors = ErrorBox()
        let saver = CredentialSaver(store: store, identitySync: identitySync) { error in
            reportedErrors.append(error)
        }

        try await saver.save(WebCredential(domain: "example.com", username: "alice", password: "s3cret"))
        try await saver.remove(domain: "example.com", username: "alice")

        XCTAssertTrue(try store.credentials(forDomain: "example.com").isEmpty)
        XCTAssertEqual(reportedErrors.errors as? [SpyError], [.boom])
    }
}
