import Foundation
import WebKit

/// The app-side facade for the WebExtensions MV3 engine: owns the registry
/// and services, installs the `browser.*` bridge into web views, and opens
/// extension popups.
@MainActor
public final class WebExtensionHost {
    public let registry: WebExtensionRegistry
    public let storage: ExtensionStorageService
    public let router: ExtensionMessageRouter

    private let storageDirectory: URL

    public init(storageDirectory: URL, defaults: Foundation.UserDefaults = .standard) {
        self.storageDirectory = storageDirectory
        self.registry = WebExtensionRegistry(defaults: defaults)
        self.storage = ExtensionStorageService(
            directory: storageDirectory.appendingPathComponent("storage", isDirectory: true))
        self.router = ExtensionMessageRouter(registry: registry, storage: storage)
    }

    /// Installs the bridge into a web view's configuration (called before
    /// the web view is created, or once per fresh configuration).
    public func installBridge(into controller: WKUserContentController) {
        controller.removeScriptMessageHandler(forName: BrowserBridgeScript.messageHandlerName)
        controller.add(router, name: BrowserBridgeScript.messageHandlerName)
        let script = WKUserScript(
            source: BrowserBridgeScript.source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        controller.addUserScript(script)
    }

    /// Removes the bridge (web view teardown).
    public func uninstallBridge(from controller: WKUserContentController) {
        controller.removeScriptMessageHandler(forName: BrowserBridgeScript.messageHandlerName)
        controller.removeAllUserScripts()
    }

    public var extensions: [WebExtension] {
        registry.extensions
    }

    public func install(bundleDirectory: URL) throws -> WebExtension {
        try registry.install(bundleDirectory: bundleDirectory)
    }
}
