import Foundation
import BrowserCore

// MARK: - Availability

/// The feature's availability, distilled from the FoundationModels
/// `SystemLanguageModel.Availability` tri-state by `SummarizeSession` (the
/// only file that touches the framework). Kept dependency-free so this file
/// compiles and tests on any Mac and any SDK.
public enum SummarizeAvailability: Equatable, Sendable {
    case available
    /// Model published but not ready. Self-heals: the OS publishes the model
    /// later, so re-check on app foreground instead of caching "unavailable".
    case notReadyYet
    /// Device not eligible or Apple Intelligence disabled by the user.
    /// Vanish cleanly: no grey-out, no explanation, no nag.
    case unavailable
}

/// How the feature should present itself, given the last availability check.
public enum SummarizeFeaturePresence: Equatable, Sendable {
    case hidden
    case available
    /// Present but waiting on the model; re-check on foreground.
    case notReady
}

/// Pure availability state machine. The rules:
/// - `available` → the command exists.
/// - `notReadyYet` → nothing shown right now, but `shouldRecheckOnForeground`
///   is true — the state can self-heal and must not be cached as permanent.
/// - `unavailable` → hidden forever (until the next launch check); never a
///   greyed-out item with an explanation nobody reads.
public enum SummarizePresenceMachine {
    public static func presence(
        from availability: SummarizeAvailability,
        previous: SummarizeFeaturePresence = .hidden
    ) -> SummarizeFeaturePresence {
        switch availability {
        case .available: return .available
        case .notReadyYet: return .notReady
        case .unavailable: return .hidden
        }
    }

    public static func shouldRecheckOnForeground(_ presence: SummarizeFeaturePresence) -> Bool {
        presence == .notReady
    }
}

// MARK: - Errors

public enum SummarizeError: Error, Equatable {
    case unavailable
    case notReadyYet
    case extractionFailed
    case deferredByEnergy
    case generationFailed(refusalCount: Int, detail: String)
}

// MARK: - Retry policy

/// Respond-path refusals are nondeterministic noise, not a content verdict
/// (foundation-models-probe finding 2). Bounded retry at the probed ≤3, then
/// quiet failure. The real error and the refusal count go to logs only.
public struct SummarizeRetryPolicy: Equatable, Sendable {
    public var maxAttempts: Int

    public init(maxAttempts: Int = 3) {
        self.maxAttempts = max(1, maxAttempts)
    }

    public func shouldRetry(afterRefusals refusals: Int) -> Bool {
        refusals < maxAttempts
    }
}

/// User-facing strings. The refusal copy ("May contain sensitive content")
/// is radioactive: it must never render. The UI string is the only one a
/// user who asked to summarize a news article should ever see on failure.
public enum SummarizeUI {
    public static let failureMessage = "Couldn't summarize this page."

    public static func logLine(refusalCount: Int, detail: String) -> String {
        "summarize failed after \(refusalCount) refusal(s): \(detail)"
    }
}

// MARK: - Energy gate

/// Inference only at `.normal`. Under memory pressure or critical thermal the
/// tier is already demoted by `EnergyGovernor.tier(for:)` (the shipped
/// memory-pressure input maps normal→conserve, conserve/critical→critical),
/// so this single check quietly absent the feature exactly when the machine
/// cannot afford inference — the reason that input exists.
public enum SummarizeEnergyGate {
    public static func allows(tier: EnergyTier) -> Bool {
        tier == .normal
    }
}

// MARK: - Prompt

/// One simple prompt, deliberately. The model mutates under OS updates; keep
/// prompts simple and validation loose (probe culture: change one variable
/// per run).
public enum SummarizePrompt {
    public static func forText(_ text: String) -> String {
        "Summarise the following page in exactly three sentences:\n\n\(text)"
    }
}
