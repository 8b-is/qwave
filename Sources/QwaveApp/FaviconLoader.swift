import AppKit
import Foundation
import Persistence

/// Fetches and caches site favicons. The fetch deliberately carries NO
/// cookies and stores nothing (ephemeral session, cookies disabled): a
/// favicon request must never leak one container's identity into another's
/// universe, and no cookies at all is strictly stronger isolation than
/// per-container cookies. The cache is still keyed per container so icon
/// *presence* metadata never crosses containers either.
@MainActor
final class FaviconLoader {
    private var cache: [String: NSImage] = [:]
    private var inFlight: Set<String> = []
    private let session: URLSession
    private let store: FaviconStore?

    init(store: FaviconStore? = nil) {
        self.store = store
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration)
    }

    private func key(host: String, containerID: UUID?) -> String {
        "\(containerID?.uuidString ?? "default")|\(host)"
    }

    func cachedIcon(forHost host: String?, containerID: UUID?) -> NSImage? {
        guard let host else { return nil }
        let cacheKey = key(host: host, containerID: containerID)
        if let memoryCached = cache[cacheKey] {
            return memoryCached
        }

        // Asynchronously load from persistent SQLite FaviconStore if available
        if let store, !inFlight.contains(cacheKey) {
            inFlight.insert(cacheKey)
            Task { @MainActor [weak self] in
                defer { self?.inFlight.remove(cacheKey) }
                if let data = try? await store.load(host: host, containerID: containerID),
                    let image = NSImage(data: data) {
                    image.size = NSSize(width: 16, height: 16)
                    self?.cache[cacheKey] = image
                }
            }
        }

        return nil
    }

    /// Fetches `iconURL`, caching under the PAGE host (the host the tab
    /// shows, not the CDN the icon happens to live on).
    func load(
        iconURL: URL,
        pageHost: String?,
        containerID: UUID?,
        completion: @escaping @MainActor (NSImage?) -> Void
    ) {
        guard let pageHost else {
            completion(nil)
            return
        }
        let cacheKey = key(host: pageHost, containerID: containerID)
        if let cached = cache[cacheKey] {
            completion(cached)
            return
        }
        guard !inFlight.contains(cacheKey) else { return }
        inFlight.insert(cacheKey)

        Task { @MainActor [weak self] in
            defer { self?.inFlight.remove(cacheKey) }
            guard let (data, response) = try? await self?.session.data(from: iconURL),
                let http = response as? HTTPURLResponse, http.statusCode == 200,
                data.count <= 512 * 1024,
                let image = NSImage(data: data)
            else {
                completion(nil)
                return
            }
            image.size = NSSize(width: 16, height: 16)
            self?.cache[cacheKey] = image

            // Persist to SQLite store
            if let store = self?.store {
                Task {
                    try? await store.store(
                        host: pageHost,
                        containerID: containerID,
                        data: data
                    )
                }
            }

            completion(image)
        }
    }
}
