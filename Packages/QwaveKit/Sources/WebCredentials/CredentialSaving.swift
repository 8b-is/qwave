import Foundation

/// A candidate login parsed from a page's form-submission event, decoded from
/// what the in-page capture shim hands the browser. Value type on purpose —
/// no `WebKit`/`AppKit` dependency, fully unit-testable — mirroring how
/// `PasskeyAssertionRequest` decodes the passkey bridge's payload.
///
/// The password never leaves the device: this only travels from page JS to
/// the app's own message handler over `WKScriptMessageHandler`, which never
/// crosses a process or network boundary.
public struct CapturedFormCredential: Sendable, Equatable {
    public let domain: String
    public let username: String
    public let password: String

    public init(domain: String, username: String, password: String) {
        self.domain = domain
        self.username = username
        self.password = password
    }

    /// Build from the JSON-ish payload the in-page capture shim posts on form
    /// submit: `{ url, username, password }`. `url` is normalised through
    /// ``WebCredentialMatching/normalize(_:)`` — the same rule the store and
    /// the AutoFill extension already key on — so a captured login and a
    /// later fill request agree on the domain. Rejects a blank domain,
    /// username, or password: there is nothing worth prompting to save.
    public init?(json: [String: Any]) {
        guard
            let url = json["url"] as? String,
            let username = json["username"] as? String, !username.isEmpty,
            let password = json["password"] as? String, !password.isEmpty
        else {
            return nil
        }
        let domain = WebCredentialMatching.normalize(url)
        guard !domain.isEmpty else { return nil }
        self.domain = domain
        self.username = username
        self.password = password
    }

    public var asWebCredential: WebCredential {
        WebCredential(domain: domain, username: username, password: password)
    }
}

/// Keeps the system's AutoFill index (`ASCredentialIdentityStore` on Apple
/// platforms) in sync with the credentials Qwave itself stores.
///
/// This protocol is deliberately Foundation-only: `WebCredentials` stays
/// crypto-free and framework-light (see the module's product comment in
/// `Package.swift`), so the real `ASCredentialIdentityStore`-backed
/// implementation lives app-side, where `AuthenticationServices` is already
/// linked (see `SystemCredentialIdentityStore` in `Sources/QwaveApp`). Tests
/// exercise ``CredentialSaver`` against a fake conforming to this protocol
/// instead.
///
/// The store only ever holds *metadata* — service + account — never the
/// secret. Nothing here ever sees a password.
public protocol CredentialIdentitySyncing: Sendable {
    /// Register (or update) the identity for a saved login so the system can
    /// offer it in QuickType / the AutoFill bar without the extension having
    /// to be opened first.
    func registerIdentity(for credential: WebCredential) async throws
    /// Remove a previously-registered identity. No-op if it was never
    /// registered (e.g. AutoFill was disabled when the login was saved).
    func removeIdentity(domain: String, username: String) async throws
}

/// Does nothing. Useful as a default where identity sync genuinely isn't
/// wanted (tests, platforms without `AuthenticationServices`).
public struct NoOpCredentialIdentitySyncing: CredentialIdentitySyncing {
    public init() {}
    public func registerIdentity(for credential: WebCredential) async throws {}
    public func removeIdentity(domain: String, username: String) async throws {}
}

/// The missing write path (see issue #72): the single place that turns a
/// captured or imported login into (1) a `WebCredentialStore` write and (2)
/// an `ASCredentialIdentityStore` registration, so the two never drift apart.
///
/// Callers that only touched `WebCredentialStore.save` directly (as the
/// keychain implementation always allowed) would persist a working login that
/// the system's QuickType index never learns about — the extension could
/// still fill it via the interactive list, but proactive suggestions would
/// never appear. Routing every save/remove through here closes that gap.
public struct CredentialSaver: Sendable {
    private let store: any WebCredentialStore
    private let identitySync: any CredentialIdentitySyncing
    /// Identity-sync failures are reported here rather than failing the
    /// overall save: the credential is already durably written to the
    /// keychain by the time identity sync runs, and losing a login because
    /// QuickType metadata couldn't be updated would be a worse outcome than a
    /// login that only shows up via the interactive AutoFill list.
    private let onIdentitySyncError: (@Sendable (Error) -> Void)?

    public init(
        store: any WebCredentialStore,
        identitySync: any CredentialIdentitySyncing,
        onIdentitySyncError: (@Sendable (Error) -> Void)? = nil
    ) {
        self.store = store
        self.identitySync = identitySync
        self.onIdentitySyncError = onIdentitySyncError
    }

    /// Insert or update `credential` and register/refresh its AutoFill
    /// identity. The keychain write happens first and is the operation that
    /// can throw to the caller; identity sync is best-effort.
    public func save(_ credential: WebCredential) async throws {
        try store.save(credential)
        do {
            try await identitySync.registerIdentity(for: credential)
        } catch {
            onIdentitySyncError?(error)
        }
    }

    /// Remove a login and its AutoFill identity.
    public func remove(domain: String, username: String) async throws {
        try store.remove(domain: domain, username: username)
        do {
            try await identitySync.removeIdentity(domain: domain, username: username)
        } catch {
            onIdentitySyncError?(error)
        }
    }
}
