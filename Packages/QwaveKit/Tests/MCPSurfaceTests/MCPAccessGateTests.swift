import Foundation
import Persistence
import XCTest

@testable import MCPSurface

/// The gate itself, against a real `UserDefaults` suite rather than a stub —
/// the production path is "read a key out of a defaults domain", so that is
/// what is exercised.
final class MCPAccessGateTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "is.8b.qwave.mcp-tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testAnAbsentKeyIsOff() {
        XCTAssertNil(defaults.object(forKey: SettingsStore.mcpServerEnabledKey))
        XCTAssertFalse(MCPAccessGate(defaults: defaults).isEnabled)
    }

    func testExplicitFalseIsOff() {
        defaults.set(false, forKey: SettingsStore.mcpServerEnabledKey)
        XCTAssertFalse(MCPAccessGate(defaults: defaults).isEnabled)
    }

    func testExplicitTrueIsOn() {
        defaults.set(true, forKey: SettingsStore.mcpServerEnabledKey)
        XCTAssertTrue(MCPAccessGate(defaults: defaults).isEnabled)
    }

    /// A non-boolean value is not consent. `defaults write … -string 1` is a
    /// plausible fumble, and `bool(forKey:)` reads it as true — the gate uses
    /// `object(forKey:) as? Bool`, which does not, and must stay that way.
    func testAStringOneIsNotConsentEvenThoughBoolForKeySaysItIs() {
        defaults.set("1", forKey: SettingsStore.mcpServerEnabledKey)
        XCTAssertTrue(
            defaults.bool(forKey: SettingsStore.mcpServerEnabledKey),
            "precondition: bool(forKey:) is the lenient reader this gate avoids")
        XCTAssertFalse(MCPAccessGate(defaults: defaults).isEnabled)
    }

    /// The gate is re-read per call, so consent revoked in Settings takes
    /// effect on an already-running server process.
    func testRevokingConsentTakesEffectWithoutReconstructingTheGate() {
        defaults.set(true, forKey: SettingsStore.mcpServerEnabledKey)
        let gate = MCPAccessGate(defaults: defaults)
        XCTAssertTrue(gate.isEnabled)
        defaults.set(false, forKey: SettingsStore.mcpServerEnabledKey)
        XCTAssertFalse(gate.isEnabled)
    }

    /// The writer (`SettingsStore`, in the app) and the out-of-process reader
    /// must use one key. If either side ever hard-codes its own literal, this
    /// fails.
    @MainActor
    func testSettingsStoreWritesTheKeyTheGateReads() {
        let settings = SettingsStore(defaults: defaults)
        XCTAssertFalse(settings.mcpServerEnabled, "SettingsStore must default the MCP surface to OFF")
        XCTAssertFalse(MCPAccessGate(defaults: defaults).isEnabled)

        settings.mcpServerEnabled = true
        XCTAssertTrue(MCPAccessGate(defaults: defaults).isEnabled)

        settings.mcpServerEnabled = false
        XCTAssertFalse(MCPAccessGate(defaults: defaults).isEnabled)
    }

    func testTheDisabledMessageDoesNotDiscloseWhetherAProfileExists() {
        let message = MCPAccessGate.disabledMessage
        XCTAssertTrue(message.contains(SettingsStore.mcpServerEnabledKey))
        XCTAssertFalse(message.contains("browser.db"))
        XCTAssertFalse(message.contains("session.json"))
    }
}

final class QwaveProfileLocationTests: XCTestCase {
    /// `qwave-mcp` cannot link the app target, so it repeats two literals the
    /// app owns. Pin them here: if `BrowserEnvironment.supportDirectory` or the
    /// app's bundle identifier in `project.yml` ever moves, this is the tripwire.
    func testProfileLayoutMatchesTheApp() {
        let location = QwaveProfileLocation.default
        XCTAssertEqual(location.directory.lastPathComponent, "Qwave")
        XCTAssertTrue(location.directory.path.contains("Application Support"))
        XCTAssertEqual(location.browserDatabase.lastPathComponent, "browser.db")
        XCTAssertEqual(location.sessionSnapshot.lastPathComponent, "session.json")
        XCTAssertEqual(QwaveProfileLocation.applicationDefaultsSuite, "is.8b.qwave")
    }

    func testProfileDirectoryVariableRedirectsTheReader() {
        let redirected = QwaveProfileLocation.resolved(
            environment: [QwaveProfileLocation.profileDirectoryVariable: "/tmp/scratch-profile"])
        XCTAssertEqual(redirected.browserDatabase.path, "/tmp/scratch-profile/browser.db")

        XCTAssertEqual(QwaveProfileLocation.resolved(environment: [:]), .default)
        XCTAssertEqual(
            QwaveProfileLocation.resolved(
                environment: [QwaveProfileLocation.profileDirectoryVariable: ""]),
            .default)
    }

    /// The redirect must move the reader and nothing else. If it could reach
    /// the gate, an attacker-supplied environment would be consent.
    func testProfileDirectoryVariableCannotOpenTheGate() {
        let suiteName = "is.8b.qwave.mcp-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        setenv(QwaveProfileLocation.profileDirectoryVariable, "/tmp/scratch-profile", 1)
        defer { unsetenv(QwaveProfileLocation.profileDirectoryVariable) }
        XCTAssertFalse(MCPAccessGate(defaults: defaults).isEnabled)
    }
}
