import AppKit
import WebCredentials
import WebKit
import os

// The other half of the write path issue #72 found missing: until now nothing
// under Sources/ ever called `WebCredentialStore.save`. This bridge is the
// capture prompt docs/AUTOFILL.md's Deferred list called out as unwired.

/// Detects a password-form submission in the page, asks the user whether to
/// save it, and — on confirmation — routes it through ``CredentialSaver`` so
/// it lands in both the keychain and the system's AutoFill identity index.
///
/// Mirrors `WebAuthnBridge`'s shape: a small `WKUserScript` posts a message on
/// a native-relevant DOM event, this handler decides what to do with it. Like
/// that bridge, it is scoped to the **main frame only** — a cross-origin
/// subframe (an embedded widget, an ad) has no business prompting to save a
/// login for the top-level site, and the frame check happens here rather than
/// relying on the user script's injection scope for the same reason
/// `WebAuthnBridge` documents: registering the message handler on
/// `WKUserContentController` exposes it to every frame regardless of where
/// the shim is injected.
@available(macOS 14.0, *)
@MainActor
final class PasswordCaptureBridge: NSObject, WKScriptMessageHandler {
    static let messageName = "qwavePasswordCapture"

    private let saver: CredentialSaver
    private let existingCredentials: (String) -> [WebCredential]
    private let log = Logger(subsystem: "is.8b.qwave", category: "password-capture")

    /// - Parameters:
    ///   - saver: writes a confirmed save to the keychain + identity index.
    ///   - existingCredentials: looks up what's already stored for a domain,
    ///     so an unchanged login that's already saved doesn't re-prompt on
    ///     every sign-in. Callers pass the same store `saver` writes to.
    init(saver: CredentialSaver, existingCredentials: @escaping (String) -> [WebCredential]) {
        self.saver = saver
        self.existingCredentials = existingCredentials
    }

    /// Listens for a capture-phase `submit` on the document and, if the
    /// submitted form carries a non-empty password field, posts the domain +
    /// best-guess username + password. Never calls `preventDefault` — this
    /// only observes; the real navigation is untouched. Runs at document-end
    /// so it survives pages that replace the DOM after `DOMContentLoaded`.
    static var userScript: WKUserScript {
        let source = """
            (function () {
              if (window.__qwavePasswordCaptureInstalled) { return; }
              window.__qwavePasswordCaptureInstalled = true;
              function usernameFor(form, passwordField) {
                const candidates = form.querySelectorAll(
                  'input[autocomplete="username"], input[type="email"], input[type="text"], input[type="tel"]'
                );
                for (const el of candidates) {
                  if (el.value && el.compareDocumentPosition(passwordField) & Node.DOCUMENT_POSITION_FOLLOWING) {
                    return el.value;
                  }
                }
                for (const el of candidates) {
                  if (el.value) { return el.value; }
                }
                return '';
              }
              document.addEventListener('submit', function (event) {
                const form = event.target;
                if (!(form instanceof HTMLFormElement)) { return; }
                const passwordField = form.querySelector('input[type="password"]');
                if (!passwordField || !passwordField.value) { return; }
                const username = usernameFor(form, passwordField);
                try {
                  window.webkit.messageHandlers.qwavePasswordCapture.postMessage({
                    url: window.location.href,
                    username: username,
                    password: passwordField.value,
                  });
                } catch (e) {
                  // No handler installed (e.g. private-window policy) — nothing to do.
                }
              }, true);
            })();
            """
        return WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.frameInfo.isMainFrame else {
            log.error("refusing password capture from a subframe")
            return
        }
        guard
            let body = message.body as? [String: Any],
            let captured = CapturedFormCredential(json: body)
        else {
            return
        }

        // Don't nag: if this exact login is already stored, there's nothing
        // to save.
        let alreadyStored = existingCredentials(captured.domain).contains(captured.asWebCredential)
        guard !alreadyStored else { return }

        guard let window = message.webView?.window else { return }
        promptToSave(captured, presentingIn: window)
    }

    private func promptToSave(_ captured: CapturedFormCredential, presentingIn window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = "Save Password?"
        alert.informativeText = "Save the password for \(captured.username) on \(captured.domain) in Qwave?"
        alert.addButton(withTitle: "Save Password")
        alert.addButton(withTitle: "Not Now")
        alert.alertStyle = .informational

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.save(captured)
        }
    }

    private func save(_ captured: CapturedFormCredential) {
        Task {
            do {
                try await saver.save(captured.asWebCredential)
            } catch {
                log.error("failed to save captured credential: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
