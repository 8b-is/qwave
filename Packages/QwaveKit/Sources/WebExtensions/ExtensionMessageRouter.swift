import Foundation
import WebKit

/// A single native <-> page RPC exchange: the page's bridge call.
///
/// Its JavaScript values remain on the main actor with their WebKit source.
@MainActor
public struct ExtensionBridgeCall {
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
@MainActor
public protocol ExtensionMessageResponding {
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
    public var runtimeMessageHandler: (@MainActor (Any, @escaping @MainActor (Any?) -> Void) -> Void)?
    /// Called when an extension listener replies to a dispatched message via `sendResponse`.
    public var onMessageReplyHandler: (@MainActor (Int, Any?) -> Void)?
    public var responder: ExtensionMessageResponding?

    public init(registry: WebExtensionRegistry, storage: ExtensionStorageService) {
        self.registry = registry
        self.storage = storage
        super.init()
    }

    // MARK: - WKScriptMessageHandler

    public func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
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
        case "runtime.onMessageReply":
            let replyPayload = firstArg
            onMessageReplyHandler?(call.id, replyPayload)
        default:
            respond(call.id, success: false, value: "Unknown method: \(call.method)")
        }
    }

    private func respond(_ id: Int, success: Bool, value: Any?) {
        responder?.respond(id: id, success: success, value: value)
    }

    // MARK: - Message Dispatch & Fan-out into WebViews

    /// Dispatches a message to all `runtime.onMessage` listeners in a targeted web view.
    public func dispatchMessage(
        to webView: WKWebView,
        message: Any,
        sender: [String: Any]? = nil,
        messageId: Int? = nil
    ) {
        let msgJson = Self.serializeJSON(message)
        let senderJson = Self.serializeJSON(sender ?? [:])
        let idArg = messageId != nil ? "\(messageId!)" : "null"
        let script = "window.__qwaveNative && window.__qwaveNative.dispatchMessage(\(msgJson), \(senderJson), \(idArg));"
        webView.evaluateJavaScript(script) { _, _ in }
    }

    /// Broadcasts a message to all registered listeners across multiple web views.
    public func broadcastMessage(
        message: Any,
        sender: [String: Any]? = nil,
        across webViews: [WKWebView]
    ) {
        for webView in webViews {
            dispatchMessage(to: webView, message: message, sender: sender)
        }
    }

    private static func serializeJSON(_ value: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: value),
            let str = String(data: data, encoding: .utf8)
        {
            return str
        }
        if let strVal = value as? String {
            let escaped = strVal.replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return "null"
    }
}

/// Evaluates bridge responses into a web view.
@MainActor
public struct WebViewBridgeResponder: ExtensionMessageResponding {
    public weak var webView: WKWebView?

    public init(webView: WKWebView) {
        self.webView = webView
    }

    public func respond(id: Int, success: Bool, value: Any?) {
        guard let webView else { return }
        let payload: String
        if let value, let data = try? JSONSerialization.data(withJSONObject: value),
            let encoded = String(data: data, encoding: .utf8)
        {
            payload = encoded
        } else {
            payload = "null"
        }
        let script = "window.__qwaveNative && window.__qwaveNative.respond(\(id), \(success), \(payload));"
        webView.evaluateJavaScript(script) { _, _ in }
    }
}
