import AppKit
import WebCredentials
import WebKit
import os

/// Bridges a page's passkey request to the app-side ``PasskeyCeremonyController``.
///
/// A minimal JS shim (injected as a `WKUserScript`) exposes
/// `window.__qwavePasskeyGet(options)` / `window.__qwavePasskeyCreate(options)`,
/// each returning a `Promise`. The shim posts the request here; this handler
/// runs the platform ceremony and resolves the promise with the raw result.
///
/// Scope note: this is a *bridge to the native ceremony*, not a spec-complete
/// `navigator.credentials` polyfill. Assembling a full `PublicKeyCredential`
/// (clientDataJSON origin binding, attestation decoding) and auto-hooking
/// `navigator.credentials.get/create` is deferred — see docs/AUTOFILL.md.
@available(macOS 14.0, *)
@MainActor
final class WebAuthnBridge: NSObject, WKScriptMessageHandler {
    static let messageName = "qwavePasskey"

    private let ceremony: PasskeyCeremonyController
    private let log = Logger(subsystem: "is.8b.qwave", category: "passkey-bridge")

    init(ceremony: PasskeyCeremonyController) {
        self.ceremony = ceremony
    }

    /// User script that defines the promise-based entry points. It never hooks
    /// `navigator.credentials` automatically; a page (or a future content
    /// script) opts in by calling the `__qwavePasskey*` functions.
    static var userScript: WKUserScript {
        let source = """
        (function () {
          if (window.__qwavePasskeyGet) { return; }
          const pending = new Map();
          let seq = 0;
          window.__qwavePasskeyResolve = function (id, ok, payload) {
            const entry = pending.get(id);
            if (!entry) { return; }
            pending.delete(id);
            ok ? entry.resolve(payload) : entry.reject(new Error(payload));
          };
          function call(kind, options) {
            return new Promise(function (resolve, reject) {
              const id = String(++seq);
              pending.set(id, { resolve: resolve, reject: reject });
              try {
                window.webkit.messageHandlers.qwavePasskey.postMessage({ id: id, kind: kind, options: options || {} });
              } catch (e) {
                pending.delete(id);
                reject(e);
              }
            });
          }
          window.__qwavePasskeyGet = function (options) { return call('get', options); };
          window.__qwavePasskeyCreate = function (options) { return call('create', options); };
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard
            let body = message.body as? [String: Any],
            let id = body["id"] as? String,
            let kind = body["kind"] as? String,
            let options = body["options"] as? [String: Any]
        else {
            log.error("malformed passkey message")
            return
        }
        let webView = message.webView

        switch kind {
        case "get":
            guard let request = PasskeyAssertionRequest(json: options) else {
                reject(id: id, message: "invalid assertion options", in: webView)
                return
            }
            ceremony.performAssertion(request) { [weak self] result in
                self?.deliverAssertion(result, id: id, in: webView)
            }
        case "create":
            guard let request = PasskeyRegistrationRequest(json: options) else {
                reject(id: id, message: "invalid registration options", in: webView)
                return
            }
            ceremony.performRegistration(request) { [weak self] result in
                self?.deliverRegistration(result, id: id, in: webView)
            }
        default:
            reject(id: id, message: "unknown passkey kind", in: webView)
        }
    }

    private func deliverAssertion(
        _ result: Result<PasskeyCeremonyController.AssertionResult, Error>,
        id: String,
        in webView: WKWebView?
    ) {
        switch result {
        case .success(let r):
            let payload: [String: Any?] = [
                "credentialId": r.credentialID,
                "authenticatorData": r.authenticatorData,
                "signature": r.signature,
                "userHandle": r.userHandle as Any?,
                "clientDataJSON": r.clientDataJSON,
            ]
            resolve(id: id, payload: payload.compactMapValues { $0 }, in: webView)
        case .failure(let error):
            reject(id: id, message: "\(error)", in: webView)
        }
    }

    private func deliverRegistration(
        _ result: Result<PasskeyCeremonyController.RegistrationResult, Error>,
        id: String,
        in webView: WKWebView?
    ) {
        switch result {
        case .success(let r):
            let payload: [String: Any] = [
                "credentialId": r.credentialID,
                "attestationObject": r.attestationObject,
                "clientDataJSON": r.clientDataJSON,
            ]
            resolve(id: id, payload: payload, in: webView)
        case .failure(let error):
            reject(id: id, message: "\(error)", in: webView)
        }
    }

    private func resolve(id: String, payload: [String: Any], in webView: WKWebView?) {
        dispatch(id: id, ok: true, payloadJS: jsonLiteral(payload), in: webView)
    }

    private func reject(id: String, message: String, in webView: WKWebView?) {
        dispatch(id: id, ok: false, payloadJS: jsonLiteral(message), in: webView)
    }

    private func dispatch(id: String, ok: Bool, payloadJS: String, in webView: WKWebView?) {
        guard let webView else { return }
        let js = "window.__qwavePasskeyResolve(\(jsonLiteral(id)), \(ok ? "true" : "false"), \(payloadJS));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Encode any JSON-serializable value as a JS literal safe to splice into an
    /// `evaluateJavaScript` string.
    private func jsonLiteral(_ value: Any) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
            let array = String(data: data, encoding: .utf8)
        else {
            return "null"
        }
        // Strip the wrapping `[` `]` we added to make the top level valid JSON.
        return String(array.dropFirst().dropLast())
    }
}
