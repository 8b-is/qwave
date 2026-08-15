import Foundation

/// How a system Focus (Work, Sleep, …) should reshape the active browsing
/// window, expressed independently of AppKit and App Intents so the mapping can
/// be unit-tested. The app layer turns a `FocusContainerDecision` into a real
/// tab switch plus a shields tightening.
public struct FocusFilterConfig: Equatable, Sendable {
    /// The persistent container the Focus binds to, or `nil` for "don't switch".
    public var containerID: UUID?
    /// A "Sleep"-style filter: force the window into an ephemeral, non-persistent
    /// container regardless of `containerID`.
    public var sleepMode: Bool
    /// Whether the Focus should tighten Shields (block ads/trackers, HTTPS-first)
    /// while active. Sleep always tightens.
    public var tightenShields: Bool

    public init(containerID: UUID?, sleepMode: Bool, tightenShields: Bool) {
        self.containerID = containerID
        self.sleepMode = sleepMode
        self.tightenShields = tightenShields
    }
}

/// The concrete action the app applies when a Focus turns on.
public struct FocusContainerDecision: Equatable, Sendable {
    /// The persistent container to switch the active window to, or `nil` when no
    /// switch is warranted (Sleep, an unknown/deleted container, or an unbound
    /// filter).
    public var switchToContainerID: UUID?
    /// Force the new tab into an ephemeral (non-persistent) container.
    public var makeEphemeral: Bool
    /// Tighten Shields while the Focus is active.
    public var tightenShields: Bool

    public init(switchToContainerID: UUID?, makeEphemeral: Bool, tightenShields: Bool) {
        self.switchToContainerID = switchToContainerID
        self.makeEphemeral = makeEphemeral
        self.tightenShields = tightenShields
    }
}

/// Maps a `FocusFilterConfig` onto a `FocusContainerDecision` given the
/// containers that currently exist. Pure: no AppKit, no I/O.
public enum FocusFilterResolver {
    public static func resolve(
        config: FocusFilterConfig,
        profiles: [ContainerProfile]
    ) -> FocusContainerDecision {
        // Sleep wins over any bound container: burn the session and tighten.
        if config.sleepMode {
            return FocusContainerDecision(
                switchToContainerID: nil, makeEphemeral: true, tightenShields: true)
        }

        guard let id = config.containerID else {
            // Unbound filter: no switch, only the shields choice applies.
            return FocusContainerDecision(
                switchToContainerID: nil, makeEphemeral: false, tightenShields: config.tightenShields)
        }

        guard let profile = profiles.first(where: { $0.id == id }) else {
            // The bound container was deleted since the filter was configured;
            // don't switch into a container that no longer exists.
            return FocusContainerDecision(
                switchToContainerID: nil, makeEphemeral: false, tightenShields: config.tightenShields)
        }

        if profile.isEphemeral {
            return FocusContainerDecision(
                switchToContainerID: nil, makeEphemeral: true, tightenShields: config.tightenShields)
        }

        return FocusContainerDecision(
            switchToContainerID: id, makeEphemeral: false, tightenShields: config.tightenShields)
    }
}
