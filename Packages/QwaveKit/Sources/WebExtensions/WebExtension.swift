import Foundation

/// An installed WebExtension: its identifier, manifest, and bundle location.
public struct WebExtension: Codable, Equatable, Sendable {
    public let id: String
    public var manifest: MV3Manifest
    /// Directory containing manifest.json and the popup HTML.
    public var bundleURL: URL

    public init(id: String, manifest: MV3Manifest, bundleURL: URL) {
        self.id = id
        self.manifest = manifest
        self.bundleURL = bundleURL
    }

    /// Loads an extension from a bundle directory (manifest.json required).
    public static func load(from directory: URL) throws -> WebExtension {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(MV3Manifest.self, from: data)
        // Stable id derived from the bundle path so re-installs keep state.
        let id = "ext-" + Self.stableHash(of: directory.standardizedFileURL.path)
        return WebExtension(id: id, manifest: manifest, bundleURL: directory)
    }

    public var popupURL: URL? {
        guard let popupPath = manifest.popupPath else { return nil }
        return bundleURL.appendingPathComponent(popupPath)
    }

    /// FNV-1a, stable across launches (unlike `String.hashValue`).
    public static func stableHash(of string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

/// The set of installed extensions, persisted to UserDefaults.
@MainActor
public final class WebExtensionRegistry {
    public private(set) var extensions: [WebExtension] = []

    private let defaults: UserDefaults
    private static let storageKey = "qwave.webextensions.installed.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    public func installed(extensionID: String) -> WebExtension? {
        extensions.first { $0.id == extensionID }
    }

    @discardableResult
    public func install(bundleDirectory: URL) throws -> WebExtension {
        let ext = try WebExtension.load(from: bundleDirectory)
        if let index = extensions.firstIndex(where: { $0.id == ext.id }) {
            extensions[index] = ext
        } else {
            extensions.append(ext)
        }
        save()
        return ext
    }

    @discardableResult
    public func uninstall(extensionID: String) -> WebExtension? {
        guard let index = extensions.firstIndex(where: { $0.id == extensionID }) else {
            return nil
        }
        let removed = extensions.remove(at: index)
        save()
        return removed
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey),
            let decoded = try? JSONDecoder().decode([WebExtension].self, from: data)
        else { return }
        extensions = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(extensions) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
