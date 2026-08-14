import XCTest
@testable import Summarize
import BrowserCore

/// Pure-core tests. No FoundationModels, no WebKit runtime: this suite runs
/// on any Mac and any SDK, which is the point — the module's decisions are
/// testable where the model service cannot run.
final class SummarizePolicyTests: XCTestCase {
    // MARK: Availability state machine

    func testPresenceMachineTriState() {
        XCTAssertEqual(
            SummarizePresenceMachine.presence(from: .available),
            .available
        )
        XCTAssertEqual(
            SummarizePresenceMachine.presence(from: .notReadyYet),
            .notReady
        )
        XCTAssertEqual(
            SummarizePresenceMachine.presence(from: .unavailable),
            .hidden
        )
    }

    func testNotReadySelfHealsAndUnavailableDoesNot() {
        XCTAssertTrue(SummarizePresenceMachine.shouldRecheckOnForeground(.notReady))
        XCTAssertFalse(SummarizePresenceMachine.shouldRecheckOnForeground(.hidden))
        XCTAssertFalse(SummarizePresenceMachine.shouldRecheckOnForeground(.available))
    }

    func testUnavailableNeverGreyOuts() {
        // The vanish-cleanly rule: an unavailable state must map to hidden,
        // never to a visible-but-inert presence.
        let presence = SummarizePresenceMachine.presence(from: .unavailable)
        XCTAssertNotEqual(presence, .available)
        XCTAssertNotEqual(presence, .notReady)
        XCTAssertEqual(presence, .hidden)
    }

    // MARK: Retry policy

    func testRetryPolicyBounds() {
        let policy = SummarizeRetryPolicy(maxAttempts: 3)
        XCTAssertTrue(policy.shouldRetry(afterRefusals: 0))
        XCTAssertTrue(policy.shouldRetry(afterRefusals: 2))
        XCTAssertFalse(policy.shouldRetry(afterRefusals: 3))
        XCTAssertFalse(policy.shouldRetry(afterRefusals: 9))
    }

    func testRetryPolicyClampsToOne() {
        XCTAssertEqual(SummarizeRetryPolicy(maxAttempts: 0).maxAttempts, 1)
        XCTAssertEqual(SummarizeRetryPolicy(maxAttempts: -4).maxAttempts, 1)
        XCTAssertTrue(SummarizeRetryPolicy(maxAttempts: 1).shouldRetry(afterRefusals: 0))
        XCTAssertFalse(SummarizeRetryPolicy(maxAttempts: 1).shouldRetry(afterRefusals: 1))
    }

    // MARK: UI neutrality — refusal copy is radioactive

    func testFailureMessageNeverMentionsSensitivity() {
        XCTAssertEqual(SummarizeUI.failureMessage, "Couldn't summarize this page.")
        XCTAssertFalse(SummarizeUI.failureMessage.lowercased().contains("sensitive"))
        XCTAssertFalse(SummarizeUI.failureMessage.lowercased().contains("content"))
    }

    func testLogLineCarriesRefusalCountAndDetail() {
        let line = SummarizeUI.logLine(refusalCount: 2, detail: "refusal(Refusal…)")
        XCTAssertTrue(line.contains("2"))
        XCTAssertTrue(line.contains("refusal"))
        XCTAssertTrue(line.contains("Refusal"))
    }

    // MARK: Energy gate — including the shipped memory-pressure input

    func testEnergyGateOnlyNormal() {
        XCTAssertTrue(SummarizeEnergyGate.allows(tier: .normal))
        XCTAssertFalse(SummarizeEnergyGate.allows(tier: .conserve))
        XCTAssertFalse(SummarizeEnergyGate.allows(tier: .critical))
    }

    func testMemoryPressureDemotesTierAndClosesGate() {
        // The P1c input that shipped on main: under memory pressure, the
        // governor demotes normal → conserve; inference is quietly absent.
        let conditions = EnergyConditions(
            thermalState: .nominal,
            lowPowerMode: false,
            allWindowsOccluded: false,
            underMemoryPressure: true
        )
        let tier = EnergyGovernor.tier(for: conditions)
        XCTAssertEqual(tier, .conserve)
        XCTAssertFalse(SummarizeEnergyGate.allows(tier: tier))
    }

    func testCriticalThermalClosesGate() {
        let conditions = EnergyConditions(
            thermalState: .critical,
            lowPowerMode: false,
            allWindowsOccluded: false,
            underMemoryPressure: false
        )
        XCTAssertFalse(SummarizeEnergyGate.allows(tier: EnergyGovernor.tier(for: conditions)))
    }

    // MARK: Prompt

    func testPromptStaysSingleAndSimple() {
        let prompt = SummarizePrompt.forText("hello")
        XCTAssertTrue(prompt.contains("exactly three sentences"))
        XCTAssertTrue(prompt.hasSuffix("hello"))
    }

    // MARK: Extraction script parity guard

    func testBundledScriptLoadsAndHasTheHeuristic() {
        // Cheap guard that the resource ships and is the probe script
        // (scoring + boilerplate penalties + the >=20-char extraction filter).
        let script = ArticleExtractor.script
        XCTAssertFalse(script.isEmpty)
        XCTAssertTrue(script.contains("score"))
        XCTAssertTrue(script.contains(".paywall"))
        XCTAssertTrue(script.contains(">= 20"))
        XCTAssertTrue(script.contains("postMessage"))
    }

    func testExtractJSONDecode() {
        let json = #"{"text":"Hello world","source":"ARTICLE.","candidates":3}"#
        XCTAssertEqual(ArticleExtractor.text(from: json), "Hello world")
        XCTAssertNil(ArticleExtractor.text(from: #"{"text":""}"#))
        XCTAssertNil(ArticleExtractor.text(from: "not json"))
    }
}
