import AuthenticationServices
import WebCredentials
import os

// The app-side half of the write path issue #72 found missing: the only
// place in the tree that ever calls `ASCredentialIdentityStore.shared`. See
// docs/AUTOFILL.md § "ASCredentialIdentityStore".

/// Registers/removes `ASPasswordCredentialIdentity` entries in the system's
/// shared AutoFill index so Qwave's saved logins can appear as proactive
/// QuickType suggestions, not just via the extension's interactive list.
///
/// Identity-only: this never touches a secret. The password stays exactly
/// where it already lived, in `KeychainWebCredentialStore`'s
/// `kSecClassInternetPassword` items; the extension fetches it at fill time
/// (`CredentialProviderViewController.lookup(domains:)`). This type only ever
/// writes the service/account *metadata* the system uses to decide when to
/// offer Qwave's extension at all.
/// `@unchecked Sendable`: `ASCredentialIdentityStore` is Apple's documented
/// thread-safe singleton (every operation is completion-handler based and
/// safe to call from any thread), but the SDK does not mark it `Sendable`.
/// This type only ever holds an immutable reference to it plus a `Logger`
/// (itself `Sendable`), so the `@unchecked` is a narrow, load-bearing
/// assertion about a documented Apple contract, not a blanket escape hatch.
@available(macOS 14.0, *)
struct SystemCredentialIdentityStore: CredentialIdentitySyncing, @unchecked Sendable {
    /// The system hands `CredentialProviderViewController.prepareCredentialList`
    /// domain-typed service identifiers for web AutoFill requests, so the
    /// identity registered here must use the same type or it never matches a
    /// fill request.
    private static let serviceIdentifierType: ASCredentialServiceIdentifier.IdentifierType = .domain

    private let identityStore: ASCredentialIdentityStore
    private let log = Logger(subsystem: "is.8b.qwave", category: "credential-identity-sync")

    init(identityStore: ASCredentialIdentityStore = .shared) {
        self.identityStore = identityStore
    }

    func registerIdentity(for credential: WebCredential) async throws {
        guard try await extensionIsEnabled() else {
            log.debug("skipping identity registration: AutoFill extension is not enabled")
            return
        }
        let identity = passwordIdentity(for: credential)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            identityStore.saveCredentialIdentities([identity]) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if !success {
                    continuation.resume(throwing: CredentialIdentitySyncError.saveFailed)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func removeIdentity(domain: String, username: String) async throws {
        guard try await extensionIsEnabled() else { return }
        let identity = passwordIdentity(for: WebCredential(domain: domain, username: username, password: ""))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            identityStore.removeCredentialIdentities([identity]) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if !success {
                    continuation.resume(throwing: CredentialIdentitySyncError.removeFailed)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func extensionIsEnabled() async throws -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            identityStore.getState { state in
                continuation.resume(returning: state.isEnabled)
            }
        }
    }

    private func passwordIdentity(for credential: WebCredential) -> ASPasswordCredentialIdentity {
        let service = ASCredentialServiceIdentifier(
            identifier: credential.domain,
            type: Self.serviceIdentifierType
        )
        return ASPasswordCredentialIdentity(
            serviceIdentifier: service,
            user: credential.username,
            recordIdentifier: "\(credential.domain)\u{0}\(credential.username)"
        )
    }
}

enum CredentialIdentitySyncError: Error {
    case saveFailed
    case removeFailed
}
