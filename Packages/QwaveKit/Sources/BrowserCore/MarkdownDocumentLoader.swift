import Foundation
import QwaveSupport
import URLIdentity

/// A reader re-fetch owns one disposable network context. WebKit's original
/// navigation owns browser cookie updates; this second fetch never writes its
/// response cookies back to a tab (including after cancellation or replacement).
enum MarkdownDocumentLoader {
    static let maximumBytes = 8 * 1024 * 1024

    static func configuration(cookies: [HTTPCookie], protocols: [AnyClass]? = nil) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        // Ephemeral configurations own a fresh, in-memory cookie jar. Let
        // Foundation choose cookies for each URL, including redirected URLs;
        // never carry a hand-built Cookie header across origins.
        for cookie in cookies { configuration.httpCookieStorage?.setCookie(cookie) }
        if let protocols { configuration.protocolClasses = protocols }
        EgressGuard.install(into: configuration)
        return configuration
    }

    static func fetch(_ url: URL, cookies: [HTTPCookie], protocols: [AnyClass]? = nil) async throws -> (
        Data, URLResponse
    ) {
        guard isWebURL(url) else { throw URLError(.unsupportedURL) }
        try Task.checkCancellation()
        let session = URLSession(
            configuration: configuration(cookies: cookies, protocols: protocols),
            delegate: MarkdownTransportDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let request = EgressGuard.markPageDriven(URLRequest(url: url))
        let (bytes, response) = try await session.bytes(for: request)
        guard response.expectedContentLength <= Int64(maximumBytes) else { throw URLError(.dataLengthExceedsMaximum) }
        var data = Data()
        for try await byte in bytes {
            if data.count >= maximumBytes { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        try Task.checkCancellation()
        return (data, response)
    }

    static func isWebURL(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return (scheme == "https" || scheme == "http") && CanonicalHost.host(of: url) != nil
            && url.user == nil && url.password == nil
    }
}

private final class MarkdownTransportDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let url = request.url, MarkdownDocumentLoader.isWebURL(url) else {
            completionHandler(nil)
            return
        }
        // Foundation already bounds redirect chains. Preserve the page-driven
        // provenance on every hop without granting the session an exemption.
        completionHandler(EgressGuard.markPageDriven(request))
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            // WebKit's HTTP-auth and client-certificate credentials are not
            // available here. Never fall back to another tab's stored identity.
            completionHandler(.rejectProtectionSpace, nil)
        }
    }
}
