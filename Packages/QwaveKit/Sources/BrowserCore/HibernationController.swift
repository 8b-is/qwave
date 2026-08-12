import Foundation

/// Facts about one tab that the hibernation decision needs.
public struct TabHibernationInfo: Equatable, Sendable {
    public var id: UUID
    public var isSelected: Bool
    public var isPinned: Bool
    public var isPlayingMedia: Bool
    public var isHibernatable: Bool
    public var lastActivated: Date

    public init(
        id: UUID,
        isSelected: Bool,
        isPinned: Bool,
        isPlayingMedia: Bool,
        isHibernatable: Bool,
        lastActivated: Date
    ) {
        self.id = id
        self.isSelected = isSelected
        self.isPinned = isPinned
        self.isPlayingMedia = isPlayingMedia
        self.isHibernatable = isHibernatable
        self.lastActivated = lastActivated
    }
}

/// Decides which background tabs to hibernate. Pure and clock-injected so the
/// state machine tests run with a fake clock; the app layer drives `tick`
/// from a single coalesced timer and performs the actual teardown via
/// `TabHibernator`.
///
/// Exemptions: the selected tab, pinned tabs, tabs playing audio/video, and
/// tabs that have nothing to hibernate (fresh or already hibernated).
@MainActor
public final class HibernationController {
    public private(set) var timeout: TimeInterval

    public init(timeout: TimeInterval) {
        self.timeout = timeout
    }

    public func updateTimeout(_ timeout: TimeInterval) {
        self.timeout = timeout
    }

    /// Returns the ids of tabs that should hibernate now.
    public func tabsToHibernate(now: Date, tabs: [TabHibernationInfo]) -> [UUID] {
        tabs.filter { tab in
            guard tab.isHibernatable,
                  !tab.isSelected,
                  !tab.isPinned,
                  !tab.isPlayingMedia
            else { return false }
            return now.timeIntervalSince(tab.lastActivated) >= timeout
        }
        .map(\.id)
    }
}
