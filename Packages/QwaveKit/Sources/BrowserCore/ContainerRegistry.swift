import Foundation
import WebKit
import Combine
import QwaveSupport

/// A Firefox-style container: its own cookie/storage universe, visually
/// tagged. Backed by `WKWebsiteDataStore(forIdentifier:)`, so isolation is
/// enforced by WebKit's storage layer (separate cookie jars, caches, service
/// workers, local storage), on top of WebKit's per-site process isolation.
public struct ContainerProfile: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var colorHex: String
    public var isEphemeral: Bool

    public init(id: UUID = UUID(), name: String, colorHex: String, isEphemeral: Bool = false) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.isEphemeral = isEphemeral
    }
}

@MainActor
public final class ContainerRegistry: ObservableObject {
    /// Built-in burner profile: fresh non-persistent store per tab.
    public static let ephemeralProfileID = UUID(uuidString: "00000000-0000-0000-0000-00000000EE01")!

    @Published public private(set) var profiles: [ContainerProfile]

    private let fileURL: URL?

    public init(directory: URL?) {
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.fileURL = directory.appendingPathComponent("containers.json")
        } else {
            self.fileURL = nil
        }

        if let fileURL = self.fileURL,
            let data = try? Data(contentsOf: fileURL),
            let saved = try? JSONDecoder().decode([ContainerProfile].self, from: data)
        {
            self.profiles = saved
        } else {
            self.profiles = [
                ContainerProfile(name: "Work", colorHex: "#4A90D9"),
                ContainerProfile(name: "Personal", colorHex: "#50B860"),
            ]
            save()
        }
    }

    public func profile(withID id: UUID?) -> ContainerProfile? {
        guard let id else { return nil }
        if id == Self.ephemeralProfileID {
            return ContainerProfile(id: id, name: "Ephemeral", colorHex: "#9B59B6", isEphemeral: true)
        }
        return profiles.first { $0.id == id }
    }

    @discardableResult
    public func createProfile(name: String, colorHex: String) -> ContainerProfile {
        let profile = ContainerProfile(name: name, colorHex: colorHex)
        profiles.append(profile)
        save()
        return profile
    }

    public func rename(id: UUID, to name: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].name = name
        save()
    }

    /// Deletes the profile and wipes its entire storage universe.
    public func deleteProfile(id: UUID) async {
        profiles.removeAll { $0.id == id }
        save()
        if #available(iOS 17.0, macOS 14.0, *) {
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: id)
                QwaveLog.browser.info("Removed data store for container \(id, privacy: .public)")
            } catch {
                // A store that was never instantiated has nothing on disk; that
                // surfaces as an error here and is fine to ignore.
                QwaveLog.browser.info(
                    "Data store removal for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        } else {
            // Identifier-backed stores do not exist on iOS 15/16: there is
            // nothing on disk to remove.
            QwaveLog.browser.info("Data store removal for \(id, privacy: .public): not supported below iOS 17")
        }
    }

    /// The data store for a tab in the given container.
    /// - nil profile → the shared default store.
    /// - ephemeral profile (or `isEphemeral` flag) → a fresh non-persistent
    ///   store per call, so every burner tab is its own universe.
    /// - persistent profile → the identifier-backed isolated store, where the
    ///   OS provides it (iOS 17+); below that, the default store, with the
    ///   degradation logged rather than hidden.
    public func dataStore(for profileID: UUID?) -> WKWebsiteDataStore {
        guard let profileID else { return .default() }
        if profileID == Self.ephemeralProfileID {
            return .nonPersistent()
        }
        guard let profile = profile(withID: profileID) else { return .default() }
        if profile.isEphemeral {
            return .nonPersistent()
        }
        if #available(iOS 17.0, macOS 14.0, *) {
            return WKWebsiteDataStore(forIdentifier: profile.id)
        }
        QwaveLog.browser.info("Identifier-backed stores need iOS 17; profile \(profileID, privacy: .public) shares the default store")
        return .default()
    }

    private func save() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(profiles) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
