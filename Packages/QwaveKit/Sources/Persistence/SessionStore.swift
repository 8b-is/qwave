import Foundation

public struct TabSnapshot: Codable, Equatable {
    public var url: URL?
    public var title: String
    public var containerID: UUID?
    public var isPinned: Bool

    public init(url: URL?, title: String, containerID: UUID?, isPinned: Bool) {
        self.url = url
        self.title = title
        self.containerID = containerID
        self.isPinned = isPinned
    }
}

public struct WindowSnapshot: Codable, Equatable {
    public var tabs: [TabSnapshot]
    public var selectedIndex: Int

    public init(tabs: [TabSnapshot], selectedIndex: Int) {
        self.tabs = tabs
        self.selectedIndex = selectedIndex
    }
}

public struct SessionSnapshot: Codable, Equatable {
    public var windows: [WindowSnapshot]
    public var savedAt: Date

    public init(windows: [WindowSnapshot], savedAt: Date = Date()) {
        self.windows = windows
        self.savedAt = savedAt
    }
}

/// Persists window/tab topology as JSON in Application Support. Ephemeral
/// tabs are excluded by the caller before saving — a burner tab that survives
/// relaunch wouldn't be a burner tab.
public final class SessionStore {
    private let fileURL: URL

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("session.json")
    }

    public func save(_ snapshot: SessionSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }

    public func load() -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
