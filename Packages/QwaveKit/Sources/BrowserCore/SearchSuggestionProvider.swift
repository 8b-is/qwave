import Foundation
import Persistence
import QwaveSupport

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

/// Shared plumbing for the per-engine suggestion providers: a cookieless
/// ephemeral session with the egress guard installed, and the shared
/// query → fetch → parse flow.
enum SuggestionTransport {
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 3.0
        // Custom configuration, so the process-wide EgressGuard registration
        // at launch does not reach this session (see EgressGuard's doc
        // comment) — install it explicitly so a request here is checked
        // against EgressAllowlist too, not just pinned by convention. See #77.
        EgressGuard.install(into: config)
        return URLSession(configuration: config)
    }

    static func fetch(
        session: URLSession,
        urlForEncodedQuery: (String) -> URL?,
        query: String,
        provider: String
    ) async throws -> [RemoteSearchSuggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
            let url = urlForEncodedQuery(encoded)
        else {
            return []
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return []
        }

        return SearchSuggestionParser.parseJSON(data, provider: provider)
    }
}

/// Privacy-first DuckDuckGo suggestion provider using ephemeral, cookieless transport.
public final class DuckDuckGoSuggestionProvider: SearchSuggestionProviding, @unchecked Sendable {
    /// Internal (not `private`) so `@testable import BrowserCore` can assert
    /// the default session is wired with `EgressGuard` (see
    /// `EgressGuardTests`), without exposing it as public API.
    let session: URLSession

    /// The host this provider's requests leave the machine for — the
    /// Category-A allowlist check key.
    public static let egressHost = "duckduckgo.com"

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            self.session = SuggestionTransport.makeSession()
        }
    }

    public func fetchSuggestions(for query: String) async throws -> [RemoteSearchSuggestion] {
        try await SuggestionTransport.fetch(
            session: session,
            urlForEncodedQuery: { encoded in
                URL(string: "https://duckduckgo.com/ac/?q=\(encoded)&type=list")
            },
            query: query,
            provider: "DuckDuckGo"
        )
    }
}

/// Ecosia's autocomplete endpoint (`ac.ecosia.org`), which answers the same
/// OpenSearch JSON shape DuckDuckGo does. Cookieless, ephemeral, opt-in —
/// the same transport posture as the DuckDuckGo provider.
public final class EcosiaSuggestionProvider: SearchSuggestionProviding, @unchecked Sendable {
    /// Internal for the same reason as `DuckDuckGoSuggestionProvider.session`.
    let session: URLSession

    /// The host this provider's requests leave the machine for — the
    /// Category-A allowlist check key.
    public static let egressHost = "ac.ecosia.org"

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            self.session = SuggestionTransport.makeSession()
        }
    }

    public func fetchSuggestions(for query: String) async throws -> [RemoteSearchSuggestion] {
        try await SuggestionTransport.fetch(
            session: session,
            urlForEncodedQuery: { encoded in
                URL(string: "https://ac.ecosia.org/autocomplete?q=\(encoded)&type=list")
            },
            query: query,
            provider: "Ecosia"
        )
    }
}

/// Maps the user's chosen search engine onto a suggestion provider and the
/// host its requests leave the machine for.
///
/// Both engines Qwave ships — Ecosia and DuckDuckGo — have a vetted, keyless
/// autocomplete endpoint, so the factory always returns a provider. The
/// optional return survives as the honest API shape: a future engine without
/// an endpoint must be able to say "no remote suggestions", never "use
/// another engine's endpoint instead".
public enum SearchSuggestionProviderFactory {
    public static func provider(for engine: SearchEngine) -> (any SearchSuggestionProviding)? {
        switch engine {
        case .ecosia: return EcosiaSuggestionProvider()
        case .duckduckgo: return DuckDuckGoSuggestionProvider()
        }
    }

    /// The Category-A host remote suggestions for this engine use.
    public static func egressHost(for engine: SearchEngine) -> String? {
        switch engine {
        case .ecosia: return EcosiaSuggestionProvider.egressHost
        case .duckduckgo: return DuckDuckGoSuggestionProvider.egressHost
        }
    }
}
