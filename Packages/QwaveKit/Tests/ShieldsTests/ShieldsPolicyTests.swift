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

    /// The bypass class from the v0.3.0 kickoff: an override saved under one
    /// spelling of a host must apply to every spelling WebKit resolves to the
    /// same identity — and only to that identity.
    func testOverrideKeysAreCanonical() {
        let policy = ShieldsPolicy(directory: nil)

        // IDN: saving under the Unicode form must match the punycode form.
        policy.setOverride(SitePolicy(adsBlocked: false), forHost: "例え.jp")
        XCTAssertFalse(policy.resolvedPolicy(forHost: "xn--r8jz45g.jp").adsBlocked)
        XCTAssertFalse(policy.resolvedPolicy(forHost: "例え.jp").adsBlocked)

        // Non-decimal IPv4 literals collapse onto the dotted-decimal identity.
        policy.setOverride(SitePolicy(jsEnabled: false), forHost: "0x7f.0.0.1")
        XCTAssertFalse(policy.resolvedPolicy(forHost: "127.0.0.1").jsEnabled)
        XCTAssertFalse(policy.resolvedPolicy(forHost: "2130706433").jsEnabled)

        // Percent-encoded spelling is the same identity.
        policy.setOverride(SitePolicy(httpsFirst: false), forHost: "ex%61mple.com")
        XCTAssertFalse(policy.resolvedPolicy(forHost: "example.com").httpsFirst)

        // A *different* confusable identity must NOT inherit the override:
        // Cyrillic "е" makes this a distinct registrable host.
        policy.setOverride(SitePolicy(adsBlocked: false), forHost: "sеcure.example")
        XCTAssertTrue(
            policy.resolvedPolicy(forHost: "secure.example").adsBlocked,
            "Latin spelling must not match the Cyrillic-confusable override"
        )

        // Bare IPv6 (Foundation's bracket-stripped spelling, and the
        // pre-v0.3.0 persisted key form) lands on the bracketed canonical key.
        policy.setOverride(SitePolicy(adsBlocked: false), forHost: "::1")
        XCTAssertFalse(policy.resolvedPolicy(forHost: "[::1]").adsBlocked)
    }

    /// Pre-v0.3.0 shields.json keys are re-normalized on load so persisted
    /// per-site settings keep applying after the canonical-host migration.
    func testLegacyPersistedKeysAreMigratedOnLoad() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwave-shields-migrate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // v0.2-era file: keys as Foundation spelled them.
        let legacy = """
        {"defaultAdsBlocked":true,"defaultHTTPSFirst":true,
         "overrides":{"::1":{"jsEnabled":false},"WWW.Example.com":{"adsBlocked":false}}}
        """
        try Data(legacy.utf8).write(to: dir.appendingPathComponent("shields.json"))

        let policy = ShieldsPolicy(directory: dir)
        XCTAssertFalse(policy.resolvedPolicy(forHost: "[::1]").jsEnabled)
        XCTAssertFalse(policy.resolvedPolicy(forHost: "example.com").adsBlocked)
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
