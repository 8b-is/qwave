import AppIntents
import Foundation
import Persistence

/// A visited page modelled as an App Intents entity, so Qwave history is
/// reachable from Shortcuts, Siri, and Spotlight. Purely local: the query
/// reads only Qwave's on-device `HistoryStore` and never phones home.
struct HistoryEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "History Entry")
    static let defaultQuery = HistoryEntityQuery()

    let id: Int
    let urlString: String
    let title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title.isEmpty ? urlString : title)",
            subtitle: "\(urlString)"
        )
    }

    init(_ entry: HistoryEntry) {
        id = Int(entry.id)
        urlString = entry.url.absoluteString
        title = entry.title
    }
}

/// Backs `HistoryEntity` for Shortcuts/Siri. Text search maps to the store's
/// own LIKE query; suggestions surface the most-visited recent pages. All
/// reads go through the live app's `HistoryStore`, so nothing is exposed that
/// the user hasn't already visited locally.
struct HistoryEntityQuery: EntityQuery, EntityStringQuery {
    @MainActor
    private func store() -> HistoryStore? {
        QwaveIntentHost.delegate?.environment?.history
    }

    @MainActor
    func entities(for identifiers: [Int]) async throws -> [HistoryEntity] {
        guard let history = store() else { return [] }
        let wanted = Set(identifiers)
        let entries = try await history.entries(limit: 1000)
        return entries.filter { wanted.contains(Int($0.id)) }.map(HistoryEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [HistoryEntity] {
        guard let history = store() else { return [] }
        return try await history.entries(matching: string, limit: 50).map(HistoryEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [HistoryEntity] {
        guard let history = store() else { return [] }
        return try await history.entries(limit: 20).map(HistoryEntity.init)
    }
}
