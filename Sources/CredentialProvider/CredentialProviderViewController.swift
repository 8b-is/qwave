import AuthenticationServices
import os

// SPIKE SCAFFOLD — see docs/AUTOFILL.md.
//
// This file is deliberately NOT yet referenced by project.yml; it is
// groundwork for a future AutoFill Credential Provider app-extension target.
// Wiring the signed target is documented as the next step in AUTOFILL.md so an
// otherwise-green `CODE_SIGNING_ALLOWED=NO` build cannot be broken by it.
//
// Every request path returns an empty result or cancels cleanly — there is no
// credential storage, no fill, and no passkey creation here. The extension is
// isolated from the PQ/DeviceKeyManager crypto stack by construction: it
// imports only AuthenticationServices and os, never VPNKit or any Packages/
// crypto module (AUTOFILL.md § "Separation from DeviceKeyManager").

/// Placeholder principal class for Qwave's AutoFill Credential Provider
/// extension. Subclasses `ASCredentialProviderViewController` (an
/// `NSViewController` on macOS) and stubs the request lifecycle so AutoFill
/// dismisses cleanly instead of hanging. Gated to macOS 14 — Qwave's
/// deployment target — so the modern request-based passkey overrides are
/// available without back-deployment shims.
@available(macOS 14.0, *)
final class CredentialProviderViewController: ASCredentialProviderViewController {
    private let log = Logger(subsystem: "is.8b.qwave.autofill", category: "credential-provider")

    // MARK: - Password AutoFill

    /// User opened the extension from the AutoFill list. The spike has no
    /// credential store, so it presents nothing to choose from.
    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        log.debug("prepareCredentialList: \(serviceIdentifiers.count, privacy: .public) identifier(s); empty list")
    }

    /// User tapped a QuickType suggestion. Nothing is unlocked in the spike, so
    /// ask the system to fall back to the interactive path.
    override func provideCredentialWithoutUserInteraction(for credentialRequest: any ASCredentialRequest) {
        extensionContext.cancelRequest(
            withError: NSError(
                domain: ASExtensionErrorDomain,
                code: ASExtensionError.userInteractionRequired.rawValue
            )
        )
    }

    /// System asked for UI to fulfil a request. Nothing is stored yet, so
    /// cancel with a not-found error and let AutoFill dismiss.
    override func prepareInterfaceToProvideCredential(for credentialRequest: any ASCredentialRequest) {
        log.debug("prepareInterfaceToProvideCredential: no stored credential; cancelling")
        extensionContext.cancelRequest(
            withError: NSError(
                domain: ASExtensionErrorDomain,
                code: ASExtensionError.credentialIdentityNotFound.rawValue
            )
        )
    }

    // MARK: - Passkeys (macOS 14+)

    /// User picked Qwave to create a new passkey. Not implemented in the spike.
    override func prepareInterface(forPasskeyRegistration registrationRequest: any ASCredentialRequest) {
        log.debug("prepareInterface(forPasskeyRegistration:): not implemented in spike; cancelling")
        extensionContext.cancelRequest(
            withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.failed.rawValue)
        )
    }

    // MARK: - Configuration

    /// Shown when the user enables/opens Qwave in Password Options. Nothing to
    /// configure in the spike.
    override func prepareInterfaceForExtensionConfiguration() {
        log.debug("prepareInterfaceForExtensionConfiguration")
        extensionContext.completeExtensionConfigurationRequest()
    }
}
