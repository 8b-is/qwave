import Foundation
import Persistence

public enum ReadingLanguageRequest {
    /// Only replay ordinary main-frame GETs. Never replay form submissions or bodies.
    @MainActor public static func adapted(_ request: URLRequest, mainFrame: Bool, currentURL: URL? = nil) -> URLRequest?
    {
        guard mainFrame, request.httpMethod == nil || request.httpMethod == "GET",
            request.httpBody == nil, request.httpBodyStream == nil,
            let url = request.url, ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
            !ReadingLanguagePreferences.shared.excludedHosts.contains(url.host?.lowercased() ?? "")
        else { return nil }
        if let currentURL, url.fragment != nil {
            var previous = URLComponents(url: currentURL, resolvingAgainstBaseURL: false)
            var next = URLComponents(url: url, resolvingAgainstBaseURL: false)
            previous?.fragment = nil; next?.fragment = nil
            if previous == next { return nil }
        }
        let language = ReadingLanguagePreferences.shared.acceptLanguage
        guard request.value(forHTTPHeaderField: "Accept-Language") != language else { return nil }
        var result = request
        result.setValue(language, forHTTPHeaderField: "Accept-Language")
        return result
    }
}
