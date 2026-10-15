import XCTest
@testable import Persistence

@MainActor
final class ReadingLanguagePreferencesTests: XCTestCase {
    func testEnglishDefaultAndRememberedOverrides() {
        let suite = "reading-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ReadingLanguagePreferences(defaults: defaults)
        XCTAssertEqual(preferences.language, "en")
        XCTAssertTrue(preferences.permits(host: "example.test", source: "ja"))
        XCTAssertFalse(preferences.permits(host: "example.test", source: "en-US"))
        preferences.language = "ja"
        preferences.excludedHosts = ["example.test"]
        preferences.excludedLanguages = ["fr"]
        let reloaded = ReadingLanguagePreferences(defaults: defaults)
        XCTAssertEqual(reloaded.language, "ja")
        XCTAssertFalse(reloaded.permits(host: "EXAMPLE.TEST", source: "en"))
        XCTAssertFalse(reloaded.permits(host: "other.test", source: "fr-FR"))
        XCTAssertTrue(reloaded.permits(host: "other.test", source: "en"))
        reloaded.automatic = false
        XCTAssertFalse(reloaded.permits(host: "other.test", source: "en"))
    }
}
