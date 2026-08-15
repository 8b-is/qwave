import Foundation
import WebKit

/// Standard MV3 `run_at` timing phases for content script injection.
public enum ContentScriptRunAt: String, Sendable, Codable, Equatable {
    case documentStart = "document_start"
    case documentEnd = "document_end"
    case documentIdle = "document_idle"

    /// Maps to WebKit's native user script injection timing.
    public var wkInjectionTime: WKUserScriptInjectionTime {
        switch self {
        case .documentStart:
            return .atDocumentStart
        case .documentEnd, .documentIdle:
            return .atDocumentEnd
        }
    }
}

/// A prepared content script payload ready for WebKit injection.
public struct InjectedContentScript: Sendable, Equatable {
    public let extensionID: String
    public let relativePath: String
    public let source: String
    public let injectionTime: WKUserScriptInjectionTime
    public let forMainFrameOnly: Bool

    public init(
        extensionID: String,
        relativePath: String,
        source: String,
        injectionTime: WKUserScriptInjectionTime,
        forMainFrameOnly: Bool = false
    ) {
        self.extensionID = extensionID
        self.relativePath = relativePath
        self.source = source
        self.injectionTime = injectionTime
        self.forMainFrameOnly = forMainFrameOnly
    }

    /// Converts this content script into a WebKit `WKUserScript`.
    ///
    /// Injected into `ExtensionContentWorld.isolated`, not the page's own JS
    /// world: page script must not be able to observe, wrap, or replace an
    /// extension's content script (or the `browser.*` bridge it talks to).
    @MainActor
    public var userScript: WKUserScript {
        WKUserScript(
            source: source,
            injectionTime: injectionTime,
            forMainFrameOnly: forMainFrameOnly,
            in: ExtensionContentWorld.isolated
        )
    }
}

/// Engine that resolves, loads, and installs content scripts for active pages.
public final class ContentScriptEngine: @unchecked Sendable {
    public init() {}

    /// Resolves matching content scripts for a given URL across all supplied extensions.
    public func resolveScripts(
        for url: URL,
        extensions: [WebExtension],
        fileLoader: (URL) throws -> String = { try String(contentsOf: $0, encoding: .utf8) }
    ) -> [InjectedContentScript] {
        var results: [InjectedContentScript] = []

        for ext in extensions {
            for scriptSpec in ext.manifest.contentScripts {
                let patterns = scriptSpec.matches.compactMap { URLMatchPattern($0) }
                let matches = patterns.contains { $0.matches(url) }
                guard matches else { continue }

                let runAt = ContentScriptRunAt(rawValue: scriptSpec.runAt ?? "document_idle") ?? .documentIdle
                let injectionTime = runAt.wkInjectionTime

                for jsFile in scriptSpec.js {
                    let fileURL = ext.bundleURL.appendingPathComponent(jsFile)
                    guard let code = try? fileLoader(fileURL) else { continue }

                    // Wrap script in an isolated IIFE with extension context annotations
                    let wrappedSource = """
                        // [Qwave Content Script: \(ext.id) - \(jsFile)]
                        (() => {
                          try {
                            \(code)
                          } catch (err) {
                            console.error('[QwaveExtension][\(ext.id)] Error in \(jsFile):', err);
                          }
                        })();
                        """

                    results.append(
                        InjectedContentScript(
                            extensionID: ext.id,
                            relativePath: jsFile,
                            source: wrappedSource,
                            injectionTime: injectionTime,
                            forMainFrameOnly: false
                        )
                    )
                }
            }
        }

        return results
    }

    /// Installs all resolved content scripts for a URL into a `WKUserContentController`.
    ///
    /// Returns the `WKUserScript` instances that were added, so a caller that
    /// tracks its own injections (see `WebExtensionHost.uninstallBridge`) can
    /// remove exactly these later without disturbing scripts anyone else
    /// added to the same, possibly shared, controller.
    @discardableResult
    @MainActor
    public func installContentScripts(
        into controller: WKUserContentController,
        for url: URL,
        extensions: [WebExtension]
    ) -> [WKUserScript] {
        let scripts = resolveScripts(for: url, extensions: extensions)
        return scripts.map { script in
            let userScript = script.userScript
            controller.addUserScript(userScript)
            return userScript
        }
    }
}
