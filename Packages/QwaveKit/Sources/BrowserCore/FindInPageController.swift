import WebKit

/// Thin wrapper over WKWebView's native find (`find(_:configuration:)`).
@MainActor
public final class FindInPageController {
    public private(set) var lastQuery: String = ""

    public init() {}

    public func find(
        _ query: String,
        in webView: WKWebView,
        forward: Bool = true,
        caseSensitive: Bool = false,
        completion: @escaping (Bool) -> Void
    ) {
        guard !query.isEmpty else {
            completion(false)
            return
        }
        lastQuery = query
        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.caseSensitive = caseSensitive
        configuration.wraps = true
        webView.find(query, configuration: configuration) { result in
            completion(result.matchFound)
        }
    }

    public func findNext(in webView: WKWebView, completion: @escaping (Bool) -> Void) {
        find(lastQuery, in: webView, forward: true, completion: completion)
    }

    public func findPrevious(in webView: WKWebView, completion: @escaping (Bool) -> Void) {
        find(lastQuery, in: webView, forward: false, completion: completion)
    }
}
