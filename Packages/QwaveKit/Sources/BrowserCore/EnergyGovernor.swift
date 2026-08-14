import Foundation

/// Inputs sampled from the system by the app layer.
public struct EnergyConditions: Equatable, Sendable {
    public var thermalState: ProcessInfo.ThermalState
    public var lowPowerMode: Bool
    /// True when every browser window is occluded (hidden/covered).
    public var allWindowsOccluded: Bool
    /// True when the process is under memory pressure (jetsam warning/critical).
    /// Inference is the feature that needs this; hibernation already reacts via thermal/LPM.
    public var underMemoryPressure: Bool

    public init(
        thermalState: ProcessInfo.ThermalState,
        lowPowerMode: Bool,
        allWindowsOccluded: Bool,
        underMemoryPressure: Bool = false
    ) {
        self.thermalState = thermalState
        self.lowPowerMode = lowPowerMode
        self.allWindowsOccluded = allWindowsOccluded
        self.underMemoryPressure = underMemoryPressure
    }
}

public enum EnergyTier: Equatable, Sendable {
    case normal
    case conserve
    case critical
}

/// What the app should do at a given tier.
public struct EnergyPolicy: Equatable, Sendable {
    /// Background-tab inactivity before hibernation.
    public var hibernationTimeout: TimeInterval
    /// Pause media in non-selected tabs.
    public var pauseBackgroundMedia: Bool
    /// Fully suspend media (stronger than pause; also blocks resume-by-page).
    public var suspendAllBackgroundMedia: Bool

    public init(
        hibernationTimeout: TimeInterval,
        pauseBackgroundMedia: Bool,
        suspendAllBackgroundMedia: Bool
    ) {
        self.hibernationTimeout = hibernationTimeout
        self.pauseBackgroundMedia = pauseBackgroundMedia
        self.suspendAllBackgroundMedia = suspendAllBackgroundMedia
    }
}

/// Pure mapping from system conditions to energy behavior. The app layer
/// samples conditions on thermal/low-power/occlusion notifications and asks
/// for the current policy; all timers coalesce into a single low-resolution
/// tick owned by the app.
public enum EnergyGovernor {
    public static func tier(for conditions: EnergyConditions) -> EnergyTier {
        let base: EnergyTier
        switch conditions.thermalState {
        case .serious, .critical:
            base = .critical
        case .fair:
            base = conditions.lowPowerMode ? .critical : .conserve
        case .nominal:
            if conditions.lowPowerMode || conditions.allWindowsOccluded {
                base = .conserve
            } else {
                base = .normal
            }
        @unknown default:
            base = .conserve
        }
        guard conditions.underMemoryPressure else { return base }
        switch base {
        case .normal: return .conserve
        case .conserve, .critical: return .critical
        }
    }

    public static func policy(for tier: EnergyTier, baseHibernationTimeout: TimeInterval) -> EnergyPolicy {
        switch tier {
        case .normal:
            return EnergyPolicy(
                hibernationTimeout: baseHibernationTimeout,
                pauseBackgroundMedia: false,
                suspendAllBackgroundMedia: false
            )
        case .conserve:
            return EnergyPolicy(
                hibernationTimeout: max(60, baseHibernationTimeout / 3),
                pauseBackgroundMedia: false,
                suspendAllBackgroundMedia: false
            )
        case .critical:
            return EnergyPolicy(
                hibernationTimeout: 60,
                pauseBackgroundMedia: true,
                suspendAllBackgroundMedia: true
            )
        }
    }

    public static func policy(for conditions: EnergyConditions, baseHibernationTimeout: TimeInterval) -> EnergyPolicy {
        policy(for: tier(for: conditions), baseHibernationTimeout: baseHibernationTimeout)
    }
}
