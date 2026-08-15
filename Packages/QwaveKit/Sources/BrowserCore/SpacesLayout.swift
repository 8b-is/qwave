import Foundation

/// One entry in the vertical Spaces sidebar. A "Space" promotes a container to
/// a first-class surface: the default (container-less) space, then each
/// persistent container profile.
public struct SpaceDescriptor: Identifiable, Equatable, Sendable {
    /// `nil` identifies the default, container-less space.
    public let id: UUID?
    public let name: String
    public let colorHex: String

    public init(id: UUID?, name: String, colorHex: String) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
    }
}

/// A tab reduced to just what space membership depends on. Keeping the sidebar
/// math on this Sendable value (rather than the AppKit-bound `Tab`) lets the
/// grouping logic be unit-tested without a web view.
public struct TabPlacement: Equatable, Sendable {
    public let id: UUID
    public let containerID: UUID?
    public let isEphemeral: Bool

    public init(id: UUID, containerID: UUID?, isEphemeral: Bool) {
        self.id = id
        self.containerID = containerID
        self.isEphemeral = isEphemeral
    }
}

/// Pure layout logic for the Spaces sidebar. AppKit-free so the window
/// controller's sidebar wiring has a tested core.
public enum SpacesLayout {
    /// Accent hue for the default space's stripe.
    public static let defaultSpaceColorHex = "#8E8E93"

    /// Ordered spaces for the sidebar: the default space first, then every
    /// persistent (non-ephemeral) container profile in registry order.
    public static func spaces(from profiles: [ContainerProfile]) -> [SpaceDescriptor] {
        var result = [SpaceDescriptor(id: nil, name: "Default", colorHex: defaultSpaceColorHex)]
        for profile in profiles where !profile.isEphemeral {
            result.append(SpaceDescriptor(id: profile.id, name: profile.name, colorHex: profile.colorHex))
        }
        return result
    }

    /// IDs of the tabs belonging to `spaceID`, preserving input order. The
    /// default space (`spaceID == nil`) collects container-less tabs. Ephemeral
    /// (burner/private) tabs are never grouped into a persistent space.
    public static func tabIDs(inSpace spaceID: UUID?, tabs: [TabPlacement]) -> [UUID] {
        tabs.filter { !$0.isEphemeral && $0.containerID == spaceID }.map(\.id)
    }

    /// The tab to activate when switching to `spaceID`: the first tab already
    /// in that space, or `nil` if the space is empty (the caller then opens a
    /// fresh tab there).
    public static func firstTabID(inSpace spaceID: UUID?, tabs: [TabPlacement]) -> UUID? {
        tabIDs(inSpace: spaceID, tabs: tabs).first
    }
}
