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
}
