import XCTest
@testable import Persistence

@MainActor
final class SettingsStoreTests: XCTestCase {
    func testUpdatesPersistInInjectedDefaults() {
        let suiteName = "qwave-settings-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let homepage = URL(string: "https://example.com/")!
        let store = SettingsStore(defaults: defaults)
        store.searchEngine = .kagi
        store.httpsFirstEnabled = false
        store.shieldsEnabledByDefault = false
        store.hibernationTimeout = 90
        store.homepage = homepage
        store.restoreSessionOnLaunch = false

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.searchEngine, .kagi)
        XCTAssertFalse(reloaded.httpsFirstEnabled)
        XCTAssertFalse(reloaded.shieldsEnabledByDefault)
        XCTAssertEqual(reloaded.hibernationTimeout, 90)
        XCTAssertEqual(reloaded.homepage, homepage)
        XCTAssertFalse(reloaded.restoreSessionOnLaunch)
    }

    func testAppearanceAndAccessibilityDefaults() {
        let suiteName = "qwave-settings-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.themeMode, .system)
        XCTAssertEqual(store.defaultPageZoom, 1.0)
        XCTAssertFalse(store.reduceMotionEnabled)
    }

    func testAppearanceAndAccessibilityPersist() {
        let suiteName = "qwave-settings-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        store.themeMode = .dark
        store.defaultPageZoom = 1.5
        store.reduceMotionEnabled = true

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.themeMode, .dark)
        XCTAssertEqual(reloaded.defaultPageZoom, 1.5)
        XCTAssertTrue(reloaded.reduceMotionEnabled)
    }

    /// Out-of-range zoom values are clamped on write and re-clamped on read
    /// (in case a stray value lands in the defaults domain another way).
    func testDefaultPageZoomIsClamped() {
        let suiteName = "qwave-settings-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        store.defaultPageZoom = 9.0
        XCTAssertEqual(store.defaultPageZoom, 3.0)
        store.defaultPageZoom = 0.1
        XCTAssertEqual(store.defaultPageZoom, 0.4)

        defaults.set(7.5, forKey: "qwave.defaultZoom")
        XCTAssertEqual(SettingsStore(defaults: defaults).defaultPageZoom, 3.0)
        defaults.set(0.05, forKey: "qwave.defaultZoom")
        XCTAssertEqual(SettingsStore(defaults: defaults).defaultPageZoom, 0.4)
    }
}
