import Foundation
import WebKit

/// Serves `qwave://` — the start page and offline mermaid/KaTeX runtime.
/// Never hits the network.
/// App-injected start-page body. A new handler instance is required per
/// `WKWebViewConfiguration` (WebKit rule).
///
/// Main-actor isolated: these hooks are installed by the app at launch (main
/// thread) and read only when WebKit serves a `qwave://` page, which WebKit
/// always delivers on the main thread. Isolation makes that contract explicit
/// instead of leaving them as nonisolated mutable global state.
@MainActor
public enum QwaveInternal {
    public static var startPageHTML: () -> String = {
        InternalPages.startHTML(memories: [], providerLabel: "Remember only")
    }
    public static var timelinePageHTML: () -> String = {
        InternalPages.timelineHTML(days: [], summary: nil, rememberEverything: false, providerLabel: "Remember only")
    }
    public static var lastTimelineSummary: String = ""
}

public enum QwaveInternalAction: Equatable {
    case submit(String)
    case remember(scope: String, text: String)
    case summarize(String)
}

public enum QwaveHTTPStatus: Equatable, Sendable {
    case ok
    case unauthorized
    case notFound
    case gone
    case badGateway
    case serviceUnavailable
    case gatewayTimeout
    case other(Int)

    public init(rawValue: Int) {
        switch rawValue {
        case 200: self = .ok
        case 401: self = .unauthorized
        case 404: self = .notFound
        case 410: self = .gone
        case 502: self = .badGateway
        case 503: self = .serviceUnavailable
        case 504: self = .gatewayTimeout
        default: self = .other(rawValue)
        }
    }
}

public final class QwaveSchemeHandler: NSObject, WKURLSchemeHandler {
    public static let scheme = "qwave"

    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        let host = url.host ?? ""
        let path = url.path

        if host == "start" || (host.isEmpty && path == "/start") {
            finish(urlSchemeTask, url: url, mime: "text/html", body: Data(QwaveInternal.startPageHTML().utf8))
            return
        }

        if host == "timeline" || (host.isEmpty && path == "/timeline") {
            finish(urlSchemeTask, url: url, mime: "text/html", body: Data(QwaveInternal.timelinePageHTML().utf8))
            return
        }

        if host == "runtime" || path.hasPrefix("/runtime/") {
            let name: String
            if host == "runtime" {
                name = String(path.drop(while: { $0 == "/" }))
            } else {
                name = String(path.dropFirst("/runtime/".count))
            }
            if let (data, mime) = Self.runtimeResource(named: name) {
                finish(urlSchemeTask, url: url, mime: mime, body: data)
            } else {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            }
            return
        }

        urlSchemeTask.didFailWithError(URLError(.unsupportedURL))
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func finish(_ task: WKURLSchemeTask, url: URL, mime: String, body: Data) {
        let response = URLResponse(
            url: url, mimeType: mime, expectedContentLength: body.count, textEncodingName: "utf-8")
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }

    public static func runtimeResource(named name: String) -> (Data, String)? {
        let cleaned = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !cleaned.isEmpty, !cleaned.contains("..") else { return nil }
        let mime: String
        switch URL(fileURLWithPath: cleaned).pathExtension.lowercased() {
        case "js": mime = "text/javascript"
        case "css": mime = "text/css"
        case "woff2": mime = "font/woff2"
        case "woff": mime = "font/woff"
        default: mime = "application/octet-stream"
        }

        #if SWIFT_PACKAGE
            let bundle = Bundle.module
        #else
            let bundle = Bundle(for: QwaveSchemeHandler.self)
        #endif

        let filename = URL(fileURLWithPath: cleaned).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: cleaned).pathExtension
        let subdir: String
        if cleaned.contains("/") {
            let folder = URL(fileURLWithPath: cleaned).deletingLastPathComponent().path
            subdir = "markdown/\(folder)"
        } else {
            subdir = "markdown"
        }

        if let url = bundle.url(forResource: filename, withExtension: ext, subdirectory: subdir),
            let data = try? Data(contentsOf: url)
        {
            return (data, mime)
        }
        // process("Resources") may flatten or keep markdown/ at the bundle root.
        if let url = bundle.url(
            forResource: filename, withExtension: ext,
            subdirectory: cleaned.contains("/") ? URL(fileURLWithPath: cleaned).deletingLastPathComponent().path : nil),
            let data = try? Data(contentsOf: url)
        {
            return (data, mime)
        }
        // `process("Resources")` flattens files; fonts land next to katex.min.css.
        if let url = bundle.url(forResource: filename, withExtension: ext),
            let data = try? Data(contentsOf: url)
        {
            return (data, mime)
        }
        return nil
    }

    /// `nonisolated` because conforming to WKURLSchemeHandler infers @MainActor
    /// for the whole type on Swift 6.1, which would otherwise force every caller
    /// (including synchronous tests) onto the main actor. This is a pure status
    /// predicate with no state, so it is safe to call from any isolation.
    public nonisolated static func shouldShowWaveError(status: QwaveHTTPStatus) -> Bool {
        switch status {
        case .notFound, .gone, .badGateway, .serviceUnavailable, .gatewayTimeout:
            true
        case .ok, .unauthorized, .other:
            false
        }
    }
}
