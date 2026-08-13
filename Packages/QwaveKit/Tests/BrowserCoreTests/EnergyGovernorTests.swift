import XCTest
@testable import BrowserCore

final class EnergyGovernorTests: XCTestCase {
    func testNominalIsNormal() {
        let tier = EnergyGovernor.tier(
            for: .init(thermalState: .nominal, lowPowerMode: false, allWindowsOccluded: false))
        XCTAssertEqual(tier, .normal)
    }

    func testLowPowerModeConserves() {
        let tier = EnergyGovernor.tier(
            for: .init(thermalState: .nominal, lowPowerMode: true, allWindowsOccluded: false))
        XCTAssertEqual(tier, .conserve)
    }

    func testOcclusionConserves() {
        let tier = EnergyGovernor.tier(
            for: .init(thermalState: .nominal, lowPowerMode: false, allWindowsOccluded: true))
        XCTAssertEqual(tier, .conserve)
    }

    func testFairThermalConserves() {
        let tier = EnergyGovernor.tier(for: .init(thermalState: .fair, lowPowerMode: false, allWindowsOccluded: false))
        XCTAssertEqual(tier, .conserve)
    }

    func testFairPlusLowPowerIsCritical() {
        let tier = EnergyGovernor.tier(for: .init(thermalState: .fair, lowPowerMode: true, allWindowsOccluded: false))
        XCTAssertEqual(tier, .critical)
    }

    func testSeriousThermalIsCritical() {
        let tier = EnergyGovernor.tier(
            for: .init(thermalState: .serious, lowPowerMode: false, allWindowsOccluded: false))
        XCTAssertEqual(tier, .critical)
    }

    func testPolicyScaling() {
        let base: TimeInterval = 900
        let normal = EnergyGovernor.policy(for: .normal, baseHibernationTimeout: base)
        XCTAssertEqual(normal.hibernationTimeout, 900)
        XCTAssertFalse(normal.suspendAllBackgroundMedia)

        let conserve = EnergyGovernor.policy(for: .conserve, baseHibernationTimeout: base)
        XCTAssertEqual(conserve.hibernationTimeout, 300)

        let critical = EnergyGovernor.policy(for: .critical, baseHibernationTimeout: base)
        XCTAssertEqual(critical.hibernationTimeout, 60)
        XCTAssertTrue(critical.pauseBackgroundMedia)
        XCTAssertTrue(critical.suspendAllBackgroundMedia)
    }

    func testConserveTimeoutNeverBelowFloor() {
        let conserve = EnergyGovernor.policy(for: .conserve, baseHibernationTimeout: 90)
        XCTAssertEqual(conserve.hibernationTimeout, 60, "conserve floor is one minute")
    }
}
