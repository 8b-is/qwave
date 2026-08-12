import XCTest
@testable import Shields

@MainActor
final class ShieldsPolicyTests: XCTestCase {
    func testDefaultsApplyWithoutOverride() {
        let policy = ShieldsPolicy(directory: nil)
        let resolved = policy.resolvedPolicy(forHost: "example.com")
        XCTAssertTrue(resolved.adsBlocked)
        XCTAssertTrue(resolved.httpsFirst)
        XCTAssertTrue(resolved.jsEnabled)
    }

    func testOverrideWinsAndNormalizesWWW() {
        let policy = ShieldsPolicy(directory: nil)
        policy.setOverride(SitePolicy(adsBlocked: false, jsEnabled: false), forHost: "www.Example.com")

        let resolved = policy.resolvedPolicy(forHost: "example.com")
        XCTAssertFalse(resolved.adsBlocked)
        XCTAssertTrue(resolved.httpsFirst, "unset field inherits default")
        XCTAssertFalse(resolved.jsEnabled)
    }

    func testEmptyOverrideIsRemoved() {
        let policy = ShieldsPolicy(directory: nil)
        policy.setOverride(SitePolicy(adsBlocked: false), forHost: "example.com")
        XCTAssertEqual(policy.overrides.count, 1)
        policy.setOverride(SitePolicy(), forHost: "example.com")
        XCTAssertTrue(policy.overrides.isEmpty)
    }

    func testPersistenceRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwave-shields-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = ShieldsPolicy(directory: dir)
        first.defaultAdsBlocked = false
        first.setOverride(SitePolicy(httpsFirst: false), forHost: "legacy.example.com")

        let second = ShieldsPolicy(directory: dir)
        XCTAssertFalse(second.defaultAdsBlocked)
        XCTAssertEqual(second.override(forHost: "legacy.example.com").httpsFirst, false)
    }
}
