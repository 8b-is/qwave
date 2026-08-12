import Foundation
import WebKit

/// A single native <-> page RPC exchange: the page's bridge call.
public struct ExtensionBridgeCall: Sendable {
    public let id: Int
    public let method: String
    public let args: [Any]

    public init(id: Int, method: String, args: [Any]) {
        self.id = id
        self.method = method
        self.args = args
    }
}

/// How the host delivers a bridge response back into the page
/// (evaluateJavaScript over `window.__qwaveNative.respond`).
public protocol ExtensionMessageResponding: Sendable {
    func respond(id: Int, success: Bool, value: Any?)
}

/// Routes `browser.*` RPC calls from injected pages to the extension
/// services. Concurrency-safe: `WKScriptMessageHandler` callbacks arrive on
/// the main thread.
@MainActor
public final class ExtensionMessageRouter: NSObject, WKScriptMessageHandler {
    public let registry: WebExtensionRegistry
    public let storage: ExtensionStorageService
    /// Callbacks supplied by the app: current tab snapshot and tab creation.
    public var tabQueryHandler: (([String: Any]) -> [[String: Any]])?
    public var tabCreateHandler: (([String: Any]) -> Void)?
    /// Called for `runtime.sendMessage`; may reply asynchronously via the
    /// provided closure (single reply per message, per the API).
    public var runtimeMessageHandler: ((Any, @escaping (Any?) -> Void) -> Void)?
    public var responder: ExtensionMessageResponding?

    public init(registry: WebExtensionRegistry, storage: ExtensionStorageService) {
        self.registry = registry
        self.storage = storage
        super.init()
    }

    // MARK: - WKScriptMessageHandler

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == BrowserBridgeScript.messageHandlerName,
              let body = message.body as? [String: Any],
              let id = body["id"] as? Int,
              let method = body["method"] as? String
        else { return }
        let args = (body["args"] as? [Any]) ?? []
        let call = ExtensionBridgeCall(id: id, method: method, args: args)
        let extensionID = "page"
        handle(call, extensionID: extensionID)
    }

    // MARK: - Routing

    func handle(_ call: ExtensionBridgeCall, extensionID: String) {
        // JSON null arrives as NSNull; normalize to Swift nil.
        let firstArg: Any? = {
            guard let value = call.args.first else { return nil }
            return value is NSNull ? nil : value
        }()
        switch call.method {
        case "storage.local.get":
            do {
                let value = try storage.get(extensionID: extensionID, keys: firstArg)
                respond(call.id, success: true, value: value)
            } catch {
                respond(call.id, success: false, value: error.localizedDescription)
            }
        case "storage.local.set":
            let items = (call.args.first as? [String: Any]) ?? [:]
            storage.set(extensionID: extensionID, items: items)
            respond(call.id, success: true, value: nil)
        case "storage.local.remove":
            do {
                try storage.remove(extensionID: extensionID, keys: firstArg)
                respond(call.id, success: true, value: nil)
            } catch {
                respond(call.id, success: false, value: error.localizedDescription)
            }
        case "tabs.query":
            let query = (call.args.first as? [String: Any]) ?? [:]
            let tabs = tabQueryHandler?(query) ?? []
            respond(call.id, success: true, value: tabs)
        case "tabs.create":
            let props = (call.args.first as? [String: Any]) ?? [:]
            tabCreateHandler?(props)
            respond(call.id, success: true, value: nil)
        case "runtime.sendMessage":
            let payload = firstArg
            guard let runtimeMessageHandler else {
                respond(call.id, success: true, value: nil)
                return
            }
            runtimeMessageHandler(payload ?? NSNull()) { [weak self] reply in
                self?.respond(call.id, success: true, value: reply ?? NSNull())
            }
        default:
            respond(call.id, success: false, value: "Unknown method: \(call.method)")
        }
    }

    private func respond(_ id: Int, success: Bool, value: Any?) {
        responder?.respond(id: id, success: success, value: value)
    }
}

/// Evaluates bridge responses into a web view.
public struct WebViewBridgeResponder: ExtensionMessageResponding {
    public weak var webView: WKWebView?

    public init(webView: WKWebView) {
        self.webView = webView
    }

    public func respond(id: Int, success: Bool, value: Any?) {
        guard let webView else { return }
        let payload: String
        if let value, let data = try? JSONSerialization.data(withJSONObject: value),
           let encoded = String(data: data, encoding: .utf8) {
            payload = encoded
        } else {
            payload = "null"
        }
        let script = "window.__qwaveNative && window.__qwaveNative.respond(\(id), \(success), \(payload));"
        webView.evaluateJavaScript(script) { _, _ in }
    }
}
