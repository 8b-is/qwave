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

    /// User scripts this host has added to a given `WKUserContentController`,
    /// keyed by the controller's identity. `WKUserContentController` is often
    /// shared with other installers (e.g. the WebAuthn passkey shim in
    /// `BrowserWindowController`), so `uninstallBridge(from:)` must remove
    /// only the entries recorded here rather than resetting the controller
    /// wholesale — see issue #76.
    private var installedUserScripts: [ObjectIdentifier: [WKUserScript]] = [:]

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
        installedUserScripts[ObjectIdentifier(controller), default: []].append(script)
    }

    /// Injects matching content scripts for the given target URL.
    public func installContentScripts(into controller: WKUserContentController, for url: URL) {
        let scripts = contentScriptEngine.installContentScripts(
            into: controller,
            for: url,
            extensions: registry.extensions
        )
        installedUserScripts[ObjectIdentifier(controller), default: []].append(contentsOf: scripts)
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

    /// Removes the bridge and this host's user scripts (web view teardown).
    ///
    /// `controller` is frequently shared with other installers — e.g. the
    /// WebAuthn passkey shim adds its own user script to the same
    /// `WKUserContentController` in `BrowserWindowController.ensureWebView`.
    /// A blanket `removeAllUserScripts()` would wipe those out too, so this
    /// removes only the specific `WKUserScript` instances this host added
    /// via `installBridge(into:)` / `installContentScripts(into:for:)`,
    /// leaving everything else on the controller untouched. See issue #76.
    ///
    /// `WKUserContentController` has no API to remove a single user script
    /// by reference, only `removeAllUserScripts()`. So this snapshots the
    /// scripts that aren't ours (by identity), clears the controller, and
    /// re-adds just those — a scoped removal built out of the coarse
    /// primitive WebKit actually offers.
    public func uninstallBridge(from controller: WKUserContentController) {
        controller.removeScriptMessageHandler(
            forName: BrowserBridgeScript.messageHandlerName,
            contentWorld: ExtensionContentWorld.isolated
        )
        guard let ownScripts = installedUserScripts.removeValue(forKey: ObjectIdentifier(controller)) else {
            return
        }
        let scriptsToKeep = controller.userScripts.filter { existing in
            !ownScripts.contains { $0 === existing }
        }
        controller.removeAllUserScripts()
        for script in scriptsToKeep {
            controller.addUserScript(script)
        }
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
