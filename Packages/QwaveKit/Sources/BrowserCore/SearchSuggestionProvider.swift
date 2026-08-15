import Foundation

/// A suggestion returned from a remote search engine provider.
public struct RemoteSearchSuggestion: Equatable, Sendable {
    public let text: String
    public let provider: String

    public init(text: String, provider: String = "DuckDuckGo") {
        self.text = text
        self.provider = provider
    }
}

/// Abstract contract for fetching remote search engine suggestions.
public protocol SearchSuggestionProviding: Sendable {
    func fetchSuggestions(for query: String) async throws -> [RemoteSearchSuggestion]
}

/// Parses standard OpenSearch and DuckDuckGo JSON suggestion responses.
public enum SearchSuggestionParser {
    /// Parses standard OpenSearch JSON format: `["query", ["suggestion1", "suggestion2", ...]]`
    /// or DuckDuckGo autocomplete format: `[{"phrase": "suggestion1"}, ...]`
    public static func parseJSON(_ data: Data, provider: String = "DuckDuckGo") -> [RemoteSearchSuggestion] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }

        // Format 1: OpenSearch array ["query", ["s1", "s2"]]
        if let array = root as? [Any], array.count >= 2, let list = array[1] as? [String] {
            return list.map { RemoteSearchSuggestion(text: $0, provider: provider) }
        }

        // Format 2: Array of dictionary items [{"phrase": "s1"}]
        if let dictArray = root as? [[String: Any]] {
            return dictArray.compactMap { dict in
                if let phrase = dict["phrase"] as? String {
                    return RemoteSearchSuggestion(text: phrase, provider: provider)
                }
                return nil
            }
        }

        return []
    }
}

/// Privacy-first DuckDuckGo suggestion provider using ephemeral, cookieless transport.
public final class DuckDuckGoSuggestionProvider: SearchSuggestionProviding, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            config.timeoutIntervalForRequest = 3.0
            self.session = URLSession(configuration: config)
        }
    }

    public func fetchSuggestions(for query: String) async throws -> [RemoteSearchSuggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
            let url = URL(string: "https://duckduckgo.com/ac/?q=\(encoded)&type=list")
        else {
            return []
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return []
        }

        return SearchSuggestionParser.parseJSON(data, provider: "DuckDuckGo")
    }
}
