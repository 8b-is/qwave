import AuthenticationServices
import AppKit
import WebCredentials
import os

/// App-side WebAuthn client. When a page invokes a passkey ceremony, Qwave (as
/// the relying-party client) drives it with `ASAuthorizationController` +
/// `ASAuthorizationPlatformPublicKeyCredentialProvider`, exactly the way Safari
/// does — the platform authenticator holds the passkey, not Qwave.
///
/// This path is entirely separate from the device-identity crypto stack: it
/// imports only AuthenticationServices/AppKit and the crypto-free
/// `WebCredentials` value types. It never touches DeviceKeyManager / ML-KEM.
///
/// Networking posture: this makes NO network calls. It only bridges the local
/// system authenticator UI; the page's own JS is responsible for talking to its
/// server.
@available(macOS 14.0, *)
@MainActor
final class PasskeyCeremonyController: NSObject {
    /// Raw result of a successful assertion, base64url-encoded for handing back
    /// to page JavaScript. Field assembly into a spec `PublicKeyCredential` is
    /// left to the caller / JS shim (see WebAuthnBridge, and AUTOFILL.md).
    struct AssertionResult {
        let credentialID: String
        let authenticatorData: String
        let signature: String
        let userHandle: String?
        let clientDataJSON: String
    }

    struct RegistrationResult {
        let credentialID: String
        let attestationObject: String
        let clientDataJSON: String
    }

    enum CeremonyError: Error {
        case unexpectedCredentialType
        case busy
    }

    private let log = Logger(subsystem: "is.8b.qwave", category: "passkey")
    private weak var presentationWindow: NSWindow?
    private var assertionCompletion: ((Result<AssertionResult, Error>) -> Void)?
    private var registrationCompletion: ((Result<RegistrationResult, Error>) -> Void)?

    init(presentationWindow: NSWindow?) {
        self.presentationWindow = presentationWindow
    }

    func updatePresentationWindow(_ window: NSWindow?) {
        presentationWindow = window
    }

    /// Drive `navigator.credentials.get()` for a platform passkey.
    func performAssertion(
        _ request: PasskeyAssertionRequest,
        completion: @escaping (Result<AssertionResult, Error>) -> Void
    ) {
        guard assertionCompletion == nil, registrationCompletion == nil else {
            completion(.failure(CeremonyError.busy))
            return
        }
        assertionCompletion = completion

        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: request.relyingPartyIdentifier
        )
        let assertionRequest = provider.createCredentialAssertionRequest(challenge: request.challenge)
        if !request.allowedCredentialIDs.isEmpty {
            assertionRequest.allowedCredentials = request.allowedCredentialIDs.map {
                ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0)
            }
        }
        run([assertionRequest])
    }

    /// Drive `navigator.credentials.create()` for a platform passkey.
    func performRegistration(
        _ request: PasskeyRegistrationRequest,
        completion: @escaping (Result<RegistrationResult, Error>) -> Void
    ) {
        guard assertionCompletion == nil, registrationCompletion == nil else {
            completion(.failure(CeremonyError.busy))
            return
        }
        registrationCompletion = completion

        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: request.relyingPartyIdentifier
        )
        let registrationRequest = provider.createCredentialRegistrationRequest(
            challenge: request.challenge,
            name: request.userName,
            userID: request.userID
        )
        run([registrationRequest])
    }

    private func run(_ requests: [ASAuthorizationRequest]) {
        let controller = ASAuthorizationController(authorizationRequests: requests)
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }

    private func finishAssertion(_ result: Result<AssertionResult, Error>) {
        let completion = assertionCompletion
        assertionCompletion = nil
        completion?(result)
    }

    private func finishRegistration(_ result: Result<RegistrationResult, Error>) {
        let completion = registrationCompletion
        registrationCompletion = nil
        completion?(result)
    }

    private func failAll(_ error: Error) {
        if assertionCompletion != nil { finishAssertion(.failure(error)) }
        if registrationCompletion != nil { finishRegistration(.failure(error)) }
    }
}

@available(macOS 14.0, *)
extension PasskeyCeremonyController: ASAuthorizationControllerDelegate {
    // AuthenticationServices invokes these on the main thread.
    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        MainActor.assumeIsolated {
            switch authorization.credential {
            case let assertion as ASAuthorizationPlatformPublicKeyCredentialAssertion:
                finishAssertion(.success(AssertionResult(
                    credentialID: Base64URL.encode(assertion.credentialID),
                    authenticatorData: Base64URL.encode(assertion.rawAuthenticatorData),
                    signature: Base64URL.encode(assertion.signature),
                    userHandle: assertion.userID.map(Base64URL.encode),
                    clientDataJSON: Base64URL.encode(assertion.rawClientDataJSON)
                )))
            case let registration as ASAuthorizationPlatformPublicKeyCredentialRegistration:
                finishRegistration(.success(RegistrationResult(
                    credentialID: Base64URL.encode(registration.credentialID),
                    attestationObject: registration.rawAttestationObject.map(Base64URL.encode) ?? "",
                    clientDataJSON: Base64URL.encode(registration.rawClientDataJSON)
                )))
            default:
                failAll(CeremonyError.unexpectedCredentialType)
            }
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        MainActor.assumeIsolated {
            log.debug("passkey ceremony failed: \(String(describing: error), privacy: .public)")
            failAll(error)
        }
    }
}

@available(macOS 14.0, *)
extension PasskeyCeremonyController: ASAuthorizationControllerPresentationContextProviding {
    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            presentationWindow ?? NSApp.keyWindow ?? NSWindow()
        }
    }
}
