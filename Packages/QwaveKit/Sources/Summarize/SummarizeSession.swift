import Foundation
#if canImport(FoundationModels)
    import FoundationModels
#endif

/// The result of a successful generation.
public struct SummarizeResult: Equatable, Sendable {
    public let text: String
    public let refusalCount: Int
    /// Wall time for the successful attempt (informational; not a benchmark).
    public let totalMs: Double
}

/// The only FoundationModels touchpoint in the package. Everything else in
/// the Summarize module is pure and compiles without the framework; this file
/// is gated by `canImport(FoundationModels)` + `#available(macOS 26, *)` so
/// the macOS 14 floor and the universal build compile untouched on any SDK.
///
/// Design rules encoded here (see docs/SUMMARIZE.md and
/// research/02-on-device-ai/foundation-models-probe/README.md):
/// - **Respond-only.** `streamResponse` deterministically refuses
///   page-summarisation content on macOS 26.4.1; there is no streaming code
///   path at all.
/// - Retry ≤3 on the nondeterministic refusals; refusal count returned to
///   the caller for logs, never rendered.
/// - Default guardrails; the guardrails×instructions matrix showed no
///   behavioural difference for this workload.
public enum SummarizeSession {
    /// Distilled tri-state, mapped from the SDK's
    /// `SystemLanguageModel.Availability`. Call before showing the feature.
    public static func availability() -> SummarizeAvailability {
        #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                switch SystemLanguageModel.default.availability {
                case .available:
                    return .available
                case .unavailable(.modelNotReady):
                    return .notReadyYet
                case .unavailable:
                    return .unavailable
                }
            }
        #endif
        return .unavailable
    }

    /// Summarise article text. Throws on failure; refusals are retried up to
    /// `policy.maxAttempts`. The error carries the refusal count and a log
    /// detail — neither is safe to render (see `SummarizeUI`).
    public static func summarize(
        _ text: String,
        policy: SummarizeRetryPolicy = SummarizeRetryPolicy()
    ) async throws -> SummarizeResult {
        #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                let prompt = SummarizePrompt.forText(text)
                let session = LanguageModelSession(
                    model: SystemLanguageModel(useCase: .general, guardrails: .default)
                )
                let clock = ContinuousClock()
                let started = clock.now
                var refusals = 0
                while policy.shouldRetry(afterRefusals: refusals) {
                    do {
                        let response = try await session.respond(to: prompt)
                        let elapsed = clock.now - started
                        let totalMs =
                            Double(elapsed.components.seconds) * 1_000
                            + Double(elapsed.components.attoseconds) / 1e15
                        return SummarizeResult(
                            text: response.content,
                            refusalCount: refusals,
                            totalMs: totalMs
                        )
                    } catch let e where String(describing: e).contains("refusal") {
                        refusals += 1
                        if policy.shouldRetry(afterRefusals: refusals) {
                            try? await Task.sleep(for: .milliseconds(300))
                        }
                    } catch {
                        throw SummarizeError.generationFailed(
                            refusalCount: refusals, detail: String(describing: error)
                        )
                    }
                }
                throw SummarizeError.generationFailed(
                    refusalCount: refusals, detail: "refused \(refusals) time(s)"
                )
            }
        #endif
        throw SummarizeError.unavailable
    }

    /// Fired only on explicit user intent (menu open), never on page load.
    /// Measured in P1c: whether it meaningfully cuts the warm 12–16 s is a
    /// documented footnote in docs/SUMMARIZE.md, whichever way it lands.
    public static func prewarm() {
        #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                let session = LanguageModelSession(
                    model: SystemLanguageModel(useCase: .general, guardrails: .default)
                )
                session.prewarm(promptPrefix: nil)
            }
        #endif
    }
}
