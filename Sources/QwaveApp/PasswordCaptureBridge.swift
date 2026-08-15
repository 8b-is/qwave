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
/// relying on the user script's injection scope, because registering a message
/// handler on `WKUserContentController` can expose it beyond where the shim is
/// injected.
///
/// Also like that bridge, the frame check is only half of it: the domain a
/// login is saved under comes from `frameInfo.securityOrigin`, never from the
/// message body. See ``CapturedFormCredential/init(json:frameOriginHost:)``.
@available(macOS 14.0, *)
@MainActor
final class PasswordCaptureBridge: NSObject, WKScriptMessageHandler {
    static let messageName = "qwavePasswordCapture"

    /// The shim and its message handler live in their own content world, so
    /// neither is reachable from page JS: a page cannot post a forged capture
    /// message, and — because an isolated world has its own JS global — cannot
    /// disable capture by pre-setting the shim's installed flag on `window`.
    static let contentWorld = WKContentWorld.world(name: "qwave-password-capture")

    private let saver: CredentialSaver
    private let existingCredentials: (String) -> [WebCredential]
    private var throttle = PasswordCaptureThrottle()
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
    /// submitted form carries a filled password field, posts the best-guess
    /// username plus *every* filled password field in DOM order — picking
    /// between them is ``PasswordFieldSelection``'s job, where the rule is
    /// unit-tested. Never calls `preventDefault` — this only observes; the real
    /// navigation is untouched. Runs at document-end so it survives pages that
    /// replace the DOM after `DOMContentLoaded`.
    ///
    /// No page URL is posted: the native side takes the domain from the frame's
    /// security origin, so anything the page said about its own identity would
    /// only be an invitation to lie.
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
                const filled = Array.prototype.filter.call(
                  form.querySelectorAll('input[type="password"]'),
                  function (el) { return el.value; }
                );
                if (!filled.length) { return; }
                const username = usernameFor(form, filled[0]);
                try {
                  window.webkit.messageHandlers.qwavePasswordCapture.postMessage({
                    username: username,
                    passwords: filled.map(function (el) {
                      return { value: el.value, autocomplete: el.getAttribute('autocomplete') || '' };
                    }),
                  });
                } catch (e) {
                  // No handler installed (e.g. ephemeral-tab policy) — nothing to do.
                }
              }, true);
            })();
            """
        return WKUserScript(
            source: source,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: contentWorld
        )
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.frameInfo.isMainFrame else {
            log.error("refusing password capture from a subframe")
            return
        }
        // Origin binding: the login is saved under the host WebKit reports for
        // the sending frame, so a page can only ever offer a password for
        // itself. Same rule `WebAuthnBridge` applies to a page-supplied rpId.
        let originHost = message.frameInfo.securityOrigin.host
        guard let body = message.body as? [String: Any] else { return }

        // Before any keychain work: a page can post without a user gesture.
        guard throttle.admit(origin: originHost) else {
            log.debug("dropping password capture message: rate limited")
            return
        }
        guard let captured = CapturedFormCredential(json: body, frameOriginHost: originHost) else {
            return
        }

        let outcome = PasswordCapturePolicy.outcome(
            for: captured,
            existing: existingCredentials(captured.domain)
        )
        // Don't nag: if this exact login is already stored, there's nothing
        // to save.
        guard outcome != .alreadyStored else { return }

        guard let window = message.webView?.window else { return }
        promptToSave(captured, replacesStoredPassword: outcome == .update, presentingIn: window)
    }

    private func promptToSave(
        _ captured: CapturedFormCredential,
        replacesStoredPassword: Bool,
        presentingIn window: NSWindow
    ) {
        throttle.promptDidBegin()

        let alert = NSAlert()
        if replacesStoredPassword {
            // The destructive case: a different password is already stored for
            // this login, and confirming overwrites it.
            alert.messageText = "Update the saved password for \(captured.domain)?"
            alert.informativeText =
                "Qwave already has a different password saved for \(captured.username) on "
                + "\(captured.domain). Updating replaces the stored password."
            alert.addButton(withTitle: "Update Password")
            alert.alertStyle = .warning
        } else {
            alert.messageText = "Save Password?"
            alert.informativeText = "Save the password for \(captured.username) on \(captured.domain) in Qwave?"
            alert.addButton(withTitle: "Save Password")
            alert.alertStyle = .informational
        }
        alert.addButton(withTitle: "Not Now")

        alert.beginSheetModal(for: window) { [weak self] response in
            self?.throttle.promptDidEnd()
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
