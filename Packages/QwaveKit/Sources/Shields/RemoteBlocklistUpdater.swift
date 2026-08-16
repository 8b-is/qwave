import Foundation
import QwaveSupport

/// Persists the ETag of the last fetched list, so conditional requests can
/// avoid re-downloading unchanged upstream lists.
public protocol ETagStoring: Sendable {
    func etag(for key: String) async -> String?
    func setETag(_ etag: String?, for key: String) async
}

/// UserDefaults-backed ETag store.
public actor UserDefaultsETagStore: ETagStoring {
    private let defaults: UserDefaults
    private let prefix = "qwave.blocklist.etag."

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func etag(for key: String) -> String? {
        defaults.string(forKey: prefix + key)
    }

    public func setETag(_ etag: String?, for key: String) {
        defaults.set(etag, forKey: prefix + key)
    }
}

/// Fetches an upstream uBlock/EasyList-compatible blocklist, compiles it to
/// content-blocker JSON, and caches the ETag so unchanged lists cost one
/// round trip (`304 Not Modified` → nil).
public struct RemoteBlocklistUpdater: BlocklistUpdating {
    public let sourceURL: URL
    public let etagKey: String
    private let session: URLSession
    private let etags: ETagStoring

    public init(
        sourceURL: URL,
        etagKey: String? = nil,
        session: URLSession = .shared,
        etags: ETagStoring = UserDefaultsETagStore()
    ) {
        self.sourceURL = sourceURL
        self.etagKey = etagKey ?? sourceURL.absoluteString
        self.session = session
        self.etags = etags
    }

    public func fetchUpdatedBlocklistJSON() async throws -> String? {
        var request = URLRequest(url: sourceURL)
        request.timeoutInterval = 30
        if let etag = await etags.etag(for: etagKey) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        switch http.statusCode {
        case 304:
            QwaveLog.shields.debug("Blocklist unchanged (304)")
            return nil
        case 200:
            guard let text = String(data: data, encoding: .utf8) else {
                throw URLError(.cannotDecodeContentData)
            }
            let newETag = http.value(forHTTPHeaderField: "ETag")
            await etags.setETag(newETag, for: etagKey)

            let (json, skipped, exceptions, inexpressible) = UBORuleListCompiler.compileJSON(from: text)
            QwaveLog.shields.info(
                "Blocklist updated: \(json.count, privacy: .public) bytes JSON, \(skipped, privacy: .public) skipped, \(exceptions, privacy: .public) exceptions"
            )
            // Broken out of `skipped` deliberately. A cosmetic line is expected
            // to be dropped; a filter WebKit cannot spell is a coverage hole,
            // and it used to leave no trace at all (#139).
            if inexpressible > 0 {
                QwaveLog.shields.warning(
                    "Blocklist: \(inexpressible, privacy: .public) filters declined — non-ASCII url-filter, which WebKit's content-blocker engine cannot express"
                )
            }
            return json
        default:
            throw URLError(.init(rawValue: http.statusCode))
        }
    }
}
