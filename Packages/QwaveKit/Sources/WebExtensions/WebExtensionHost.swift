import Foundation
import WebKit

/// The app-side facade for the WebExtensions MV3 engine: owns the registry
/// and services, installs the `browser.*` bridge into web views, injects
/// matching content scripts, and opens extension popups.
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

    /// Injects matching content scripts for the given target URL.
    public func installContentScripts(into controller: WKUserContentController, for url: URL) {
        contentScriptEngine.installContentScripts(
            into: controller,
            for: url,
            extensions: registry.extensions
        )
    }

    /// Resolves matching content scripts for inspection or testing.
    public func contentScripts(for url: URL) -> [InjectedContentScript] {
        contentScriptEngine.resolveScripts(for: url, extensions: registry.extensions)
    }

    /// Dispatches a message to all `browser.runtime.onMessage` listeners in a targeted web view.
    public func dispatchMessage(
        to webView: WKWebView,
        message: Any,
        sender: [String: Any]? = nil,
        messageId: Int? = nil
    ) {
        router.dispatchMessage(to: webView, message: message, sender: sender, messageId: messageId)
    }

    /// Broadcasts a message to all listeners across multiple web views.
    public func broadcastMessage(
        message: Any,
        sender: [String: Any]? = nil,
        across webViews: [WKWebView]
    ) {
        router.broadcastMessage(message: message, sender: sender, across: webViews)
    }

    /// Removes the bridge and user scripts (web view teardown).
    public func uninstallBridge(from controller: WKUserContentController) {
        controller.removeScriptMessageHandler(
            forName: BrowserBridgeScript.messageHandlerName,
            contentWorld: ExtensionContentWorld.isolated
        )
        controller.removeAllUserScripts()
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
