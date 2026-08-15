import AppIntents
import AppKit
import BrowserCore
import Foundation

// MARK: - Container entity

/// A container (or the synthetic "Sleep" option) the user can bind a system
/// Focus to. Backed by the shipped `ContainerRegistry`, so the picker in
/// Settings › Focus lists the same containers as the browser's tab bar.
struct FocusContainerEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Qwave Container"
    static let defaultQuery = FocusContainerQuery()

    /// A container's UUID string, or `sleepID` for the burner option.
    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    /// Sentinel id for the "Sleep"-style ephemeral filter.
    static let sleepID = "qwave.focus.sleep"

    static var sleep: FocusContainerEntity {
        FocusContainerEntity(id: sleepID, name: "Sleep (private, non-persistent)")
    }

    /// Translates a picked entity into the pure resolver's input.
    static func config(for entity: FocusContainerEntity?, tightenShields: Bool) -> FocusFilterConfig {
        guard let entity else {
            return FocusFilterConfig(containerID: nil, sleepMode: false, tightenShields: tightenShields)
        }
        if entity.id == sleepID {
            return FocusFilterConfig(containerID: nil, sleepMode: true, tightenShields: tightenShields)
        }
        return FocusFilterConfig(
            containerID: UUID(uuidString: entity.id), sleepMode: false, tightenShields: tightenShields)
    }
}

/// Reads the current containers for the picker, preferring the live app graph
/// and falling back to the on-disk registry when the intent runs before the app
/// has bootstrapped.
@MainActor
enum FocusContainerCatalog {
    static func currentContainers() -> [(UUID, String)] {
        if let environment = QwaveIntentHost.delegate?.environment {
            return environment.containers.profiles.map { ($0.id, $0.name) }
        }
        let registry = ContainerRegistry(directory: BrowserEnvironment.supportDirectory)
        return registry.profiles.map { ($0.id, $0.name) }
    }
}

struct FocusContainerQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [FocusContainerEntity] {
        let all = try await suggestedEntities()
        return all.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [FocusContainerEntity] {
        let containers = await FocusContainerCatalog.currentContainers()
        return [.sleep] + containers.map { FocusContainerEntity(id: $0.0.uuidString, name: $0.1) }
    }
}

// MARK: - Focus filter

/// Welds system Focus to Qwave's container isolation. When a Focus (e.g.
/// "Work") turns on, the active window switches to the bound container and —
/// optionally — Shields tighten; a "Sleep"-style filter forces an ephemeral,
/// non-persistent session.
///
/// Shields tightening is applied on enable only; relaxing defaults when the
/// Focus turns off is deferred (see the feature notes) because App Intents does
/// not deliver a symmetric "filter disabled" callback in this model.
struct ContainerFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Bind a Container to Focus"
    static let description = IntentDescription(
        """
        When this Focus turns on, Qwave switches the active window to the chosen \
        container and can tighten Shields. Pick Sleep to force a private, \
        non-persistent session.
        """,
        categoryName: "Privacy"
    )

    @Parameter(title: "Container")
    var container: FocusContainerEntity?

    @Parameter(title: "Tighten Shields", default: true)
    var tightenShields: Bool

    var displayRepresentation: DisplayRepresentation {
        let name = container?.name ?? "No container"
        let subtitle: LocalizedStringResource =
            tightenShields ? "Shields tightened" : "Shields unchanged"
        return DisplayRepresentation(title: "\(name)", subtitle: subtitle)
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let config = FocusContainerEntity.config(for: container, tightenShields: tightenShields)
        let profiles = QwaveIntentHost.delegate?.environment?.containers.profiles ?? []
        let decision = FocusFilterResolver.resolve(config: config, profiles: profiles)
        try QwaveIntentHost.applyFocus(decision)
        return .result()
    }
}
