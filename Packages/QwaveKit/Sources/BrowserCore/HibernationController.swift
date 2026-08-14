import Foundation

/// Facts about one tab that the hibernation decision needs.
public struct TabHibernationInfo: Equatable, Sendable {
    public var id: UUID
    public var isSelected: Bool
    public var isPinned: Bool
    public var isPlayingMedia: Bool
    public var isHibernatable: Bool
    public var lastActivated: Date
    /// A tab mid-load must not be hibernated: snapshotting it would both lose
    /// in-flight state and cost a foreground pause competing with the load.
    public var isLoading: Bool

    public init(
        id: UUID,
        isSelected: Bool,
        isPinned: Bool,
        isPlayingMedia: Bool,
        isHibernatable: Bool,
        lastActivated: Date,
        isLoading: Bool = false
    ) {
        self.id = id
        self.isSelected = isSelected
        self.isPinned = isPinned
        self.isPlayingMedia = isPlayingMedia
        self.isHibernatable = isHibernatable
        self.lastActivated = lastActivated
        self.isLoading = isLoading
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
    ///
    /// `foregroundIsLoading` yields the whole tick to foreground activity: while
    /// the visible tab is mid-load, no hibernation teardown runs, so a snapshot
    /// pause never competes with the page. This is a deferral, not a shutdown —
    /// the next idle tick hibernates normally (see the "resumes when idle" test).
    /// The gate reads only load/activation state the tick never mutates, so it
    /// cannot livelock: once the foreground goes idle, hibernation proceeds.
    public func tabsToHibernate(
        now: Date, tabs: [TabHibernationInfo], foregroundIsLoading: Bool = false
    ) -> [UUID] {
        guard !foregroundIsLoading else { return [] }
        return tabs.filter { tab in
            guard tab.isHibernatable,
                !tab.isSelected,
                !tab.isPinned,
                !tab.isPlayingMedia,
                !tab.isLoading
            else { return false }
            return now.timeIntervalSince(tab.lastActivated) >= timeout
        }
        .map(\.id)
    }
}
