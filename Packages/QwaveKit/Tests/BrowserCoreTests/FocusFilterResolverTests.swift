import XCTest

@testable import BrowserCore

final class FocusFilterResolverTests: XCTestCase {
    private let work = ContainerProfile(name: "Work", colorHex: "#4A90D9")
    private let personal = ContainerProfile(name: "Personal", colorHex: "#50B860")

    private var profiles: [ContainerProfile] { [work, personal] }

    func testBoundContainerSwitchesWithoutEphemeral() {
        let decision = FocusFilterResolver.resolve(
            config: FocusFilterConfig(containerID: work.id, sleepMode: false, tightenShields: true),
            profiles: profiles)
        XCTAssertEqual(decision.switchToContainerID, work.id)
        XCTAssertFalse(decision.makeEphemeral)
        XCTAssertTrue(decision.tightenShields)
    }

    func testSleepForcesEphemeralAndAlwaysTightens() {
        // Sleep ignores the bound container and forces a burner session; it
        // tightens shields even when the config asked not to.
        let decision = FocusFilterResolver.resolve(
            config: FocusFilterConfig(containerID: work.id, sleepMode: true, tightenShields: false),
            profiles: profiles)
        XCTAssertNil(decision.switchToContainerID)
        XCTAssertTrue(decision.makeEphemeral)
        XCTAssertTrue(decision.tightenShields)
    }

    func testUnknownContainerDoesNotSwitch() {
        let decision = FocusFilterResolver.resolve(
            config: FocusFilterConfig(containerID: UUID(), sleepMode: false, tightenShields: false),
            profiles: profiles)
        XCTAssertNil(decision.switchToContainerID)
        XCTAssertFalse(decision.makeEphemeral)
        XCTAssertFalse(decision.tightenShields)
    }

    func testUnboundFilterCarriesOnlyTheShieldsChoice() {
        let decision = FocusFilterResolver.resolve(
            config: FocusFilterConfig(containerID: nil, sleepMode: false, tightenShields: true),
            profiles: profiles)
        XCTAssertNil(decision.switchToContainerID)
        XCTAssertFalse(decision.makeEphemeral)
        XCTAssertTrue(decision.tightenShields)
    }

    func testEphemeralProfileResolvesToBurnerSwitch() {
        let burner = ContainerProfile(name: "Burner", colorHex: "#9B59B6", isEphemeral: true)
        let decision = FocusFilterResolver.resolve(
            config: FocusFilterConfig(containerID: burner.id, sleepMode: false, tightenShields: false),
            profiles: [burner])
        XCTAssertNil(decision.switchToContainerID)
        XCTAssertTrue(decision.makeEphemeral)
        XCTAssertFalse(decision.tightenShields)
    }
}
