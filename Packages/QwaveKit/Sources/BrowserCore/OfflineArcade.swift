import Foundation

/// A bundled arcade on its own origin: never runs game scripts as the failed website.
public enum OfflineArcade {
    public static func pageURL(error: NSError, failingURL: URL?) -> URL? {
        guard error.domain == NSURLErrorDomain,
              [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost].contains(error.code),
              let failingURL, ["https", "http"].contains(failingURL.scheme?.lowercased() ?? "")
        else { return nil }
        var parts = URLComponents(string: "qwave://arcade")!
        parts.queryItems = [URLQueryItem(name: "retry", value: failingURL.absoluteString)]
        return parts.url
    }

    public static func html(retry: String?) -> String {
        let bundle = Bundle.module
        guard let file = bundle.url(forResource: "offline-arcade", withExtension: "html"),
              let template = try? String(contentsOf: file, encoding: .utf8) else {
            return "<h1>Connection lost</h1><p>Please try your page again.</p>"
        }
        let url = retry.flatMap(URL.init(string:))
        let safe = url.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0.absoluteString : nil }
        let escaped = (safe ?? "qwave://start").replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "'", with: "&#39;")
        return template.replacingOccurrences(of: "{{RETRY_URL}}", with: escaped)
    }
}
