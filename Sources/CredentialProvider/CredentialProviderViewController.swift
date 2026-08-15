import AppKit
import AuthenticationServices
import WebCredentials
import os

// AutoFill Credential Provider extension — see docs/AUTOFILL.md.
//
// This runs OUT OF PROCESS from the browser. It fills website logins the user
// saved in Qwave, which live as synchronizable internet-password items in the
// OS keychain (iCloud Keychain when enabled). It links ONLY AuthenticationServices,
// AppKit, os, and the crypto-free WebCredentials module — never VPNKit, ML-KEM,
// DeviceKeyManager, or MemoryCipher (AUTOFILL.md § "Separation from DeviceKeyManager").

/// Principal class for Qwave's AutoFill Credential Provider extension. On macOS
/// `ASCredentialProviderViewController` is an `NSViewController`; the overrides
/// below implement the request lifecycle for password AutoFill. Gated to macOS
/// 14 (Qwave's deployment floor) so the request-based overrides are available.
@available(macOS 14.0, *)
final class CredentialProviderViewController: ASCredentialProviderViewController {
    private let log = Logger(subsystem: "is.8b.qwave.autofill", category: "credential-provider")

    /// Shared keychain, default access group. Both the browser (which saves) and
    /// this extension (which fills) resolve `nil` to the single
    /// `keychain-access-groups` entry in their entitlements — the shared group —
    /// so they interoperate without hard-coding the team-id prefix.
    private let store: any WebCredentialStore = KeychainWebCredentialStore(accessGroup: nil)

    // MARK: - Password AutoFill

    /// User opened the extension from the AutoFill list for a set of services.
    /// Present every matching saved login; tapping one fills it.
    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        let domains = serviceIdentifiers.map { WebCredentialMatching.normalize($0.identifier) }
        let matches = lookup(domains: domains)
        log.debug("prepareCredentialList: \(matches.count, privacy: .public) match(es)")
        renderList(matches)
    }

    /// User tapped a QuickType suggestion. Fill directly when there is exactly
    /// one match and no unlock is needed; otherwise fall back to the UI path.
    override func provideCredentialWithoutUserInteraction(for credentialRequest: any ASCredentialRequest) {
        guard credentialRequest.type == .password,
              let identity = credentialRequest.credentialIdentity as? ASPasswordCredentialIdentity
        else {
            cancel(.credentialIdentityNotFound)
            return
        }
        let domain = WebCredentialMatching.normalize(identity.serviceIdentifier.identifier)
        let matches = lookup(domains: [domain]).filter { $0.username == identity.user }
        guard let credential = matches.first else {
            // Nothing to fill without UI — ask the system for the interactive path.
            cancel(.userInteractionRequired)
            return
        }
        complete(with: credential)
    }

    /// System needs UI to fulfil the request. Present the matches for this
    /// identity so the user can confirm which login to fill.
    override func prepareInterfaceToProvideCredential(for credentialRequest: any ASCredentialRequest) {
        guard credentialRequest.type == .password,
              let identity = credentialRequest.credentialIdentity as? ASPasswordCredentialIdentity
        else {
            cancel(.credentialIdentityNotFound)
            return
        }
        let domain = WebCredentialMatching.normalize(identity.serviceIdentifier.identifier)
        let matches = lookup(domains: [domain])
        log.debug("prepareInterfaceToProvideCredential: \(matches.count, privacy: .public) match(es)")
        renderList(matches)
    }

    // MARK: - Passkeys (macOS 14+)

    /// User picked Qwave to create a new passkey. Passkey *storage* in the
    /// extension is deferred (see AUTOFILL.md Follow-ups); cancel cleanly.
    override func prepareInterface(forPasskeyRegistration registrationRequest: any ASCredentialRequest) {
        log.debug("prepareInterface(forPasskeyRegistration:): not implemented; cancelling")
        cancel(.failed)
    }

    // MARK: - Configuration

    /// Shown when the user enables/opens Qwave in Password Options. Nothing to
    /// configure yet.
    override func prepareInterfaceForExtensionConfiguration() {
        log.debug("prepareInterfaceForExtensionConfiguration")
        extensionContext.completeExtensionConfigurationRequest()
    }

    // MARK: - Helpers

    private func lookup(domains: [String]) -> [WebCredential] {
        var seen = Set<String>()
        var result: [WebCredential] = []
        for domain in domains where !domain.isEmpty {
            let credentials: [WebCredential]
            do {
                credentials = try store.credentials(forDomain: domain)
            } catch {
                log.error("keychain lookup failed: \(String(describing: error), privacy: .public)")
                continue
            }
            for credential in credentials {
                let key = "\(credential.domain)\u{0}\(credential.username)"
                if seen.insert(key).inserted {
                    result.append(credential)
                }
            }
        }
        return result
    }

    private func complete(with credential: WebCredential) {
        let passwordCredential = ASPasswordCredential(user: credential.username, password: credential.password)
        extensionContext.completeRequest(withSelectedCredential: passwordCredential, completionHandler: nil)
    }

    private func cancel(_ code: ASExtensionError.Code) {
        extensionContext.cancelRequest(
            withError: NSError(domain: ASExtensionErrorDomain, code: code.rawValue)
        )
    }

    /// Minimal AppKit list: one row per match, plus a Cancel control. Kept
    /// deliberately small — a richer picker is a follow-up.
    private func renderList(_ matches: [WebCredential]) {
        let container = view
        container.subviews.forEach { $0.removeFromSuperview() }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        if matches.isEmpty {
            let label = NSTextField(labelWithString: "No saved logins for this site.")
            stack.addArrangedSubview(label)
        } else {
            for (index, match) in matches.enumerated() {
                let button = NSButton(
                    title: "\(match.username) — \(match.domain)",
                    target: self,
                    action: #selector(didPickCredential(_:))
                )
                button.tag = index
                button.bezelStyle = .rounded
                stack.addArrangedSubview(button)
            }
        }

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(didCancel))
        cancelButton.bezelStyle = .rounded
        stack.addArrangedSubview(cancelButton)

        renderedMatches = matches
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
        ])
    }

    private var renderedMatches: [WebCredential] = []

    @objc private func didPickCredential(_ sender: NSButton) {
        guard renderedMatches.indices.contains(sender.tag) else {
            cancel(.credentialIdentityNotFound)
            return
        }
        complete(with: renderedMatches[sender.tag])
    }

    @objc private func didCancel() {
        cancel(.userCanceled)
    }
}
