import AppKit
import Foundation
import Persistence

/// Fetches favicons without cookies or a URLSession response cache.
/// Ordinary tabs use a per-container memory/SQLite cache. Private and
/// nonpersistent tabs receive only the fetched image, owned by that tab.
@MainActor
final class FaviconLoader {
    enum CachePolicy {
        case persistent
        case tabOnly

        init(
            isPrivateWindow: Bool,
            isEphemeralTab: Bool,
            isEphemeralContainer: Bool,
            dataStoreIsPersistent: Bool?
        ) {
            // A missing web view has no verified persistent store. Its existing
            // tab-owned favicon can still be displayed while it is hibernated.
            self =
                !isPrivateWindow && !isEphemeralTab && !isEphemeralContainer && dataStoreIsPersistent == true
                ? .persistent : .tabOnly
        }
    }

    private var cache: [String: NSImage] = [:]
    private var inFlight: Set<String> = []
    private let session: URLSession
    private let store: FaviconStore?

    init(store: FaviconStore? = nil) {
        self.store = store
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration)
    }

    private func key(host: String, containerID: UUID?) -> String {
        "\(containerID?.uuidString ?? "default")|\(host)"
    }

    func cachedIcon(forHost host: String?, containerID: UUID?, cachePolicy: CachePolicy) -> NSImage? {
        guard cachePolicy == .persistent, let host else { return nil }
        let cacheKey = key(host: host, containerID: containerID)
        if let memoryCached = cache[cacheKey] {
            return memoryCached
        }

        // Asynchronously load from persistent SQLite FaviconStore if available
        if let store, !inFlight.contains(cacheKey) {
            inFlight.insert(cacheKey)
            Task(priority: .utility) { @MainActor [weak self] in
                defer { self?.inFlight.remove(cacheKey) }
                if let data = try? await store.load(host: host, containerID: containerID),
                    let image = NSImage(data: data)
                {
                    image.size = NSSize(width: 16, height: 16)
                    self?.cache[cacheKey] = image
                }
            }
        }

        return nil
    }

    /// Fetches `iconURL`, caching under the PAGE host (the host the tab
    /// shows, not the CDN the icon happens to live on). Tab-only requests
    /// bypass every shared cache and in-flight lookup, including ordinary
    /// requests for the same host/container that are still pending.
    func load(
        iconURL: URL,
        pageHost: String?,
        containerID: UUID?,
        cachePolicy: CachePolicy,
        completion: @escaping @MainActor (NSImage?) -> Void
    ) {
        guard let pageHost else {
            completion(nil)
            return
        }
        let cacheKey = key(host: pageHost, containerID: containerID)
        if cachePolicy == .persistent {
            if let cached = cache[cacheKey] {
                completion(cached)
                return
            }
            guard !inFlight.contains(cacheKey) else { return }
            inFlight.insert(cacheKey)
        }

        Task(priority: .utility) { @MainActor [weak self] in
            defer {
                if cachePolicy == .persistent { self?.inFlight.remove(cacheKey) }
            }
            guard let (data, response) = try? await self?.session.data(from: iconURL),
                let http = response as? HTTPURLResponse, http.statusCode == 200,
                data.count <= 512 * 1024,
                let image = NSImage(data: data)
            else {
                completion(nil)
                return
            }
            image.size = NSSize(width: 16, height: 16)
            if cachePolicy == .persistent {
                self?.cache[cacheKey] = image
                if let store = self?.store {
                    Task(priority: .background) {
                        try? await store.store(
                            host: pageHost,
                            containerID: containerID,
                            data: data
                        )
                    }
                }
            }

            completion(image)
        }
    }
}
