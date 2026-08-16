import Foundation

/// `browser.storage.local` backed by a JSON file per extension. Value model
/// matches WebExtension semantics: a flat key -> JSON-value map.
@MainActor
public final class ExtensionStorageService {
    public enum StorageError: Error {
        case invalidKey
    }

    private let directory: URL
    private var cache: [String: [String: Any]] = [:]

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(for extensionID: String) -> URL {
        directory.appendingPathComponent("\(extensionID).json")
    }

    private func load(extensionID: String) -> [String: Any] {
        if let cached = cache[extensionID] {
            return cached
        }
        let url = fileURL(for: extensionID)
        let value: [String: Any]
        if let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            value = object
        } else {
            value = [:]
        }
        cache[extensionID] = value
        return value
    }

    private func save(extensionID: String, _ value: [String: Any]) {
        cache[extensionID] = value
        if let data = try? JSONSerialization.data(withJSONObject: value) {
            try? data.write(to: fileURL(for: extensionID), options: .atomic)
        }
    }

    // MARK: - API

    /// `get(keys)`: null -> everything; String -> that key; [String] -> those keys.
    ///
    /// Typed throw: `load` swallows every I/O and JSON error with `try?`, so
    /// the only thing that escapes is a caller handing us a `keys` argument the
    /// WebExtension API does not define.
    public func get(extensionID: String, keys: Any?) throws(StorageError) -> [String: Any] {
        let store = load(extensionID: extensionID)
        guard let keys else { return store }
        if let single = keys as? String {
            return store[single].map { [single: $0] } ?? [:]
        }
        if let list = keys as? [String] {
            var result: [String: Any] = [:]
            for key in list where store[key] != nil {
                result[key] = store[key]
            }
            return result
        }
        throw StorageError.invalidKey
    }

    /// `set(items)`: shallow-merge the given keys.
    public func set(extensionID: String, items: [String: Any]) {
        var store = load(extensionID: extensionID)
        for (key, value) in items {
            store[key] = value
        }
        save(extensionID: extensionID, store)
    }

    /// `remove(keys)`: String or [String].
    ///
    /// Typed throw: same closed domain as `get` — `load`/`save` swallow their
    /// own failures, so `invalidKey` is the only escape.
    public func remove(extensionID: String, keys: Any?) throws(StorageError) {
        var store = load(extensionID: extensionID)
        if let single = keys as? String {
            store.removeValue(forKey: single)
        } else if let list = keys as? [String] {
            for key in list {
                store.removeValue(forKey: key)
            }
        } else {
            throw StorageError.invalidKey
        }
        save(extensionID: extensionID, store)
    }

    public func clear(extensionID: String) {
        save(extensionID: extensionID, [:])
    }
}
