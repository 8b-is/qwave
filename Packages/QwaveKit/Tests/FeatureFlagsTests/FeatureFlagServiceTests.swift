import XCTest
import WebKit
@testable import FeatureFlags

/// SPI canary: on the runner's WebKit the reflection either finds a non-empty
/// feature set or reports the SPI unavailable — both are asserted paths, so a
/// WebKit that renames `_WKFeature` turns this test into a visible signal
/// while the browser itself degrades gracefully.
@MainActor
final class FeatureFlagServiceTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "qwave-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testDiscoveryEitherFindsFeaturesOrDegradesCleanly() {
        let service = FeatureFlagService(defaults: makeDefaults())
        if service.isSPIAvailable {
            XCTAssertFalse(service.features.isEmpty, "SPI reported available but zero features found")
            for feature in service.features.prefix(5) {
                XCTAssertFalse(feature.key.isEmpty)
                XCTAssertFalse(feature.name.isEmpty)
            }
        } else {
            XCTAssertTrue(service.features.isEmpty)
        }
    }

    func testOverridePersistsAcrossInstances() throws {
        let defaults = makeDefaults()
        let service = FeatureFlagService(defaults: defaults)
        try XCTSkipIf(!service.isSPIAvailable, "WebKit feature SPI unavailable in this environment")

        guard let candidate = service.features.first(where: { !$0.isEnabled }) ?? service.features.first else {
            throw XCTSkip("No features discovered")
        }
        let flipped = !candidate.isEnabled
        service.setEnabled(flipped, forKey: candidate.key)
        XCTAssertEqual(service.features.first(where: { $0.key == candidate.key })?.isEnabled, flipped)
        XCTAssertEqual(service.overriddenCount, 1)

        let reloaded = FeatureFlagService(defaults: defaults)
        XCTAssertEqual(reloaded.features.first(where: { $0.key == candidate.key })?.isEnabled, flipped)

        reloaded.resetAll()
        XCTAssertEqual(reloaded.overriddenCount, 0)
    }

    func testDenylistBlocksToggle() {
        let defaults = makeDefaults()
        let safety = FeatureFlagSafety(deniedKeys: ["TestBlockedFeature"], deniedPrefixes: ["Danger"])
        let service = FeatureFlagService(defaults: defaults, safety: safety)

        service.setEnabled(true, forKey: "TestBlockedFeature")
        XCTAssertEqual(service.overriddenCount, 0)

        service.setEnabled(true, forKey: "DangerZoneFlag")
        XCTAssertEqual(service.overriddenCount, 0)
    }

    func testApplyToPreferencesDoesNotCrash() {
        let service = FeatureFlagService(defaults: makeDefaults())
        if let first = service.features.first {
            service.setEnabled(first.isEnabled, forKey: first.key)
        }
        let preferences = WKPreferences()
        service.apply(to: preferences)
    }

    func testStatusMapping() {
        XCTAssertEqual(WebFeature.Status(rawStatus: 5), .preview)
        XCTAssertEqual(WebFeature.Status(rawStatus: 6), .stable)
        XCTAssertEqual(WebFeature.Status(rawStatus: 99), .unknown(99))
        XCTAssertFalse(WebFeature.Status.unknown(99).isUserFacing)
        XCTAssertTrue(WebFeature.Status.preview.isUserFacing)
    }
}
