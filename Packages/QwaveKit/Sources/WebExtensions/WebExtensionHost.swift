import Foundation
import WebKit

/// The app-side facade for the WebExtensions MV3 engine: owns the registry
/// and services, installs the `browser.*` bridge into web views, and opens
/// extension popups.
///
/// **Content scripts are not active in the shipping app.**
/// `BrowserWindowController.ensureWebView` calls ``installBridge(into:)`` and
/// nothing else, so `ContentScriptEngine` — including its match-pattern
/// resolution and its `ExtensionContentWorld.isolated` world separation — is
/// reached only from `WebExtensionsTests`. An installed extension gets the
/// `browser.*` bridge in extension pages and popups, but no `content_scripts`
/// entry in its manifest is ever injected into a tab. Wiring that up means
/// calling `contentScriptEngine.installContentScripts(into:for:extensions:)`
/// per navigation (the match set depends on the committed URL, not on the web
/// view's birth URL) and tracking the returned `WKUserScript`s so they can be
/// scoped out again on the next navigation — the controller is shared with the
/// WebAuthn shim, the password-capture shim and content blockers, so a blanket
/// `removeAllUserScripts()` is not an option (issue #76).
@MainActor
public final class WebExtensionHost {
    public let registry: WebExtensionRegistry
    public let storage: ExtensionStorageService
    public let router: ExtensionMessageRouter
    public let contentScriptEngine: ContentScriptEngine

    private let storageDirectory: URL

    public init(storageDirectory: URL, defaults: Foundation.UserDefaults = .standard) {
        self.storageDirectory = storageDirectory
        self.registry = WebExtensionRegistry(defaults: defaults)
        self.storage = ExtensionStorageService(
            directory: storageDirectory.appendingPathComponent("storage", isDirectory: true))
        self.router = ExtensionMessageRouter(registry: registry, storage: storage)
        self.contentScriptEngine = ContentScriptEngine()
    }

    /// Installs the bridge into a web view's configuration (called before
    /// the web view is created, or once per fresh configuration).
    ///
    /// With no extensions installed there is nothing for a page to talk to, so
    /// no bridge is installed at all — no `qwaveExtension` message handler, no
    /// injected script. Takes effect for web views created after an install.
    ///
    /// The bridge lives in `ExtensionContentWorld.isolated`, out of reach of
    /// page script.
    public func installBridge(into controller: WKUserContentController) {
        guard !registry.extensions.isEmpty else { return }
        controller.removeScriptMessageHandler(
            forName: BrowserBridgeScript.messageHandlerName,
            contentWorld: ExtensionContentWorld.isolated
        )
        controller.add(
            router,
            contentWorld: ExtensionContentWorld.isolated,
            name: BrowserBridgeScript.messageHandlerName
        )
        let script = WKUserScript(
            source: BrowserBridgeScript.source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: ExtensionContentWorld.isolated
        )
        controller.addUserScript(script)
    }

    /// Resolves matching content scripts for inspection or testing.
    public func contentScripts(for url: URL) -> [InjectedContentScript] {
        contentScriptEngine.resolveScripts(for: url, extensions: registry.extensions)
    }

    /// Dispatches a message to all `browser.runtime.onMessage` listeners in a
    /// targeted web view. `world` defaults to the web-page surface's world;
    /// extension chrome must pass `ExtensionContentWorld.extensionPage`.
    public func dispatchMessage(
        to webView: WKWebView,
        in world: WKContentWorld = ExtensionContentWorld.isolated,
        message: Any,
        sender: [String: Any]? = nil,
        messageId: Int? = nil
    ) {
        router.dispatchMessage(to: webView, in: world, message: message, sender: sender, messageId: messageId)
    }

    /// Broadcasts a message to all listeners across multiple web views, each
    /// paired with the world its bridge lives in.
    public func broadcastMessage(
        message: Any,
        sender: [String: Any]? = nil,
        across targets: [(webView: WKWebView, world: WKContentWorld)]
    ) {
        router.broadcastMessage(message: message, sender: sender, across: targets)
    }

    public var extensions: [WebExtension] {
        registry.extensions
    }

    public func install(bundleDirectory: URL) throws -> WebExtension {
        try registry.install(bundleDirectory: bundleDirectory)
    }

    public func uninstall(extensionID: String) -> WebExtension? {
        registry.uninstall(extensionID: extensionID)
    }
}
