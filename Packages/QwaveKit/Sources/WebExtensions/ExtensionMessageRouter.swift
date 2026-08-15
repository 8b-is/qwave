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

/// The isolated JavaScript world that hosts the `browser.*` bridge, the
/// `qwaveExtension` message handler, and every injected content script.
///
/// Page script runs in `WKContentWorld.page` and cannot read, wrap, or
/// replace anything defined here, so a hostile page can neither call the
/// native bridge nor tamper with an extension's content script.
public enum ExtensionContentWorld {
    @MainActor
    public static let isolated = WKContentWorld.world(name: "QwaveExtensions")
}

/// Encodes a value as a JavaScript literal that is safe to splice into an
/// `evaluateJavaScript` string.
enum ExtensionJSLiteral {
    /// `JSONSerialization` refuses a bare top-level fragment (a String, a
    /// number) and *raises* an Objective-C exception rather than returning an
    /// error, so `try?` cannot catch it. Wrapping the value in an array makes
    /// the top level always valid; the brackets are stripped afterwards, and
    /// JSON's own escaping — not a hand-rolled one — produces the literal.
    ///
    /// Same shape as `WebAuthnBridge.jsonLiteral` in the app target.
    static func encode(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "null" }
        guard JSONSerialization.isValidJSONObject([value]),
            let data = try? JSONSerialization.data(withJSONObject: [value]),
            let json = String(data: data, encoding: .utf8),
            json.count > 2
        else { return "null" }
        // Drop the wrapping `[` `]` added to make the top level valid JSON.
        let literal = String(json.dropFirst().dropLast())
        // JSON allows U+2028/U+2029 raw; JavaScript parsers historically treat
        // them as line terminators, so escape them before splicing into script.
        return
            literal
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
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
    /// Fallback reply sink, used only when `handle` is driven directly without an
    /// originating web view (unit tests). The live bridge always replies into the
    /// web view the call arrived from, so a reply can never land on another surface.
    var responder: ExtensionMessageResponding?

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
        // Reply into the web view this call came from. A single shared
        // responder slot would route the reply to whichever surface registered
        // last (e.g. the most recently opened popup).
        guard let sourceWebView = message.webView else { return }
        let args = (body["args"] as? [Any]) ?? []
        let call = ExtensionBridgeCall(id: id, method: method, args: args)
        let extensionID = "page"
        handle(call, extensionID: extensionID, replyTo: WebViewBridgeResponder(webView: sourceWebView))
    }

    // MARK: - Routing

    func handle(
        _ call: ExtensionBridgeCall,
        extensionID: String,
        replyTo: (any ExtensionMessageResponding)? = nil
    ) {
        let sink = replyTo ?? responder
        func respond(_ id: Int, success: Bool, value: Any?) {
            sink?.respond(id: id, success: success, value: value)
        }
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
            runtimeMessageHandler(payload ?? NSNull()) { reply in
                sink?.respond(id: call.id, success: true, value: reply ?? NSNull())
            }
        case "runtime.onMessageReply":
            let replyPayload = firstArg
            onMessageReplyHandler?(call.id, replyPayload)
        default:
            respond(call.id, success: false, value: "Unknown method: \(call.method)")
        }
    }

    // MARK: - Message Dispatch & Fan-out into WebViews

    /// Dispatches a message to all `runtime.onMessage` listeners in a targeted web view.
    public func dispatchMessage(
        to webView: WKWebView,
        message: Any,
        sender: [String: Any]? = nil,
        messageId: Int? = nil
    ) {
        let msgJson = ExtensionJSLiteral.encode(message)
        let senderJson = ExtensionJSLiteral.encode(sender ?? [:])
        let idArg = messageId != nil ? "\(messageId!)" : "null"
        let script = "window.__qwaveNative && window.__qwaveNative.dispatchMessage(\(msgJson), \(senderJson), \(idArg));"
        webView.evaluateJavaScript(script, in: nil, in: ExtensionContentWorld.isolated) { _ in }
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
        let payload = ExtensionJSLiteral.encode(value)
        let script = "window.__qwaveNative && window.__qwaveNative.respond(\(id), \(success), \(payload));"
        webView.evaluateJavaScript(script, in: nil, in: ExtensionContentWorld.isolated) { _ in }
    }
}
