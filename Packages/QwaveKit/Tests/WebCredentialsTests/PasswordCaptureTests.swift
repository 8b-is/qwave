import XCTest

@testable import WebCredentials

/// Regression tests for the password-capture bridge's rules (issue #109).
final class PasswordCaptureOriginTests: XCTestCase {
    private func payload(username: String = "victim@mail.com", password: String = "attacker-chosen") -> [String: Any] {
        [
            // A body key the parser must ignore outright: the page does not get
            // to say which domain it is.
            "url": "https://accounts.example-bank.com",
            "username": username,
            "passwords": [["value": password, "autocomplete": ""]],
        ]
    }

    /// The attack: a page on evil.com posts a capture message naming a bank it
    /// has nothing to do with. Confirming would write an attacker-chosen
    /// password under the bank's `kSecAttrServer`, overwriting the real one.
    func testDomainComesFromTheFrameOriginNotTheMessageBody() {
        let captured = CapturedFormCredential(json: payload(), frameOriginHost: "evil.com")
        XCTAssertEqual(captured?.domain, "evil.com")
    }

    /// The honest case still works, and still normalises the way the store and
    /// the AutoFill extension key on.
    func testNormalizesTheFrameOriginHost() {
        let json: [String: Any] = [
            "username": "alice",
            "passwords": [["value": "s3cret", "autocomplete": ""]],
        ]
        let captured = CapturedFormCredential(json: json, frameOriginHost: "WWW.Example.com")
        XCTAssertEqual(
            captured, CapturedFormCredential(domain: "example.com", username: "alice", password: "s3cret"))
    }

    /// `about:`/`data:` documents have no host — there is no domain to save under.
    func testRejectsAnOriginWithNoHost() {
        XCTAssertNil(CapturedFormCredential(json: payload(), frameOriginHost: ""))
    }

    func testRejectsMissingUsername() {
        var json = payload()
        json.removeValue(forKey: "username")
        XCTAssertNil(CapturedFormCredential(json: json, frameOriginHost: "example.com"))
    }

    func testRejectsEmptyPassword() {
        XCTAssertNil(CapturedFormCredential(json: payload(password: ""), frameOriginHost: "example.com"))
    }

    func testRejectsAPayloadWithNoPasswordFields() {
        let json: [String: Any] = ["username": "alice"]
        XCTAssertNil(CapturedFormCredential(json: json, frameOriginHost: "example.com"))
    }
}

final class PasswordFieldSelectionTests: XCTestCase {
    /// A change-password form in DOM order `current / new / confirm`. Taking
    /// the first field — as the shim used to — saves the *old* secret over the
    /// correct stored one.
    func testPrefersTheNewPasswordOverTheCurrentOne() {
        let fields = [
            CapturedPasswordField(value: "old-password", autocomplete: "current-password"),
            CapturedPasswordField(value: "new-password", autocomplete: "new-password"),
            CapturedPasswordField(value: "new-password", autocomplete: "new-password"),
        ]
        XCTAssertEqual(PasswordFieldSelection.submittedPassword(from: fields), "new-password")
    }

    func testHonoursSectionQualifiedAutocompleteTokens() {
        let fields = [
            CapturedPasswordField(value: "old-password", autocomplete: "section-account current-password"),
            CapturedPasswordField(value: "new-password", autocomplete: "section-account new-password"),
        ]
        XCTAssertEqual(PasswordFieldSelection.submittedPassword(from: fields), "new-password")
    }

    /// Unlabelled change-password form: the last filled field is the confirmed
    /// new password.
    func testUnlabelledChangeFormTakesTheLastFilledField() {
        let fields = [
            CapturedPasswordField(value: "old-password"),
            CapturedPasswordField(value: "new-password"),
            CapturedPasswordField(value: "new-password"),
        ]
        XCTAssertEqual(PasswordFieldSelection.submittedPassword(from: fields), "new-password")
    }

    /// A mistyped confirmation: the site will reject the change, so saving
    /// either value would store a password that never becomes real.
    func testRefusesWhenNewPasswordFieldsDisagree() {
        let fields = [
            CapturedPasswordField(value: "typed-once", autocomplete: "new-password"),
            CapturedPasswordField(value: "typed-differently", autocomplete: "new-password"),
        ]
        XCTAssertNil(PasswordFieldSelection.submittedPassword(from: fields))
    }

    func testPlainLoginFormTakesItsOnlyField() {
        let fields = [CapturedPasswordField(value: "s3cret", autocomplete: "current-password")]
        XCTAssertEqual(PasswordFieldSelection.submittedPassword(from: fields), "s3cret")
    }

    func testIgnoresEmptyFields() {
        let fields = [
            CapturedPasswordField(value: "s3cret"),
            CapturedPasswordField(value: ""),
        ]
        XCTAssertEqual(PasswordFieldSelection.submittedPassword(from: fields), "s3cret")
    }

    func testReturnsNilWhenNothingIsFilled() {
        XCTAssertNil(PasswordFieldSelection.submittedPassword(from: []))
        XCTAssertNil(PasswordFieldSelection.submittedPassword(from: [CapturedPasswordField(value: "")]))
    }

    /// End-to-end through the parser: the change-password payload the shim now
    /// posts yields the new password, not the old one.
    func testParserPicksTheNewPasswordFromTheShimPayload() {
        let json: [String: Any] = [
            "username": "alice",
            "passwords": [
                ["value": "old-password", "autocomplete": "current-password"],
                ["value": "new-password", "autocomplete": "new-password"],
            ],
        ]
        let captured = CapturedFormCredential(json: json, frameOriginHost: "example.com")
        XCTAssertEqual(captured?.password, "new-password")
    }
}

final class PasswordCapturePolicyTests: XCTestCase {
    /// An ephemeral tab exists in a normal window too (Cmd-Opt-T), and it must
    /// never persist a login.
    func testEphemeralTabInANormalWindowMayNotCapture() {
        XCTAssertFalse(
            PasswordCapturePolicy.captureIsAllowed(isPrivateWindow: false, isEphemeralTab: true))
    }

    func testPrivateWindowMayNotCapture() {
        XCTAssertFalse(
            PasswordCapturePolicy.captureIsAllowed(isPrivateWindow: true, isEphemeralTab: false))
        XCTAssertFalse(
            PasswordCapturePolicy.captureIsAllowed(isPrivateWindow: true, isEphemeralTab: true))
    }

    func testOrdinaryTabInANormalWindowMayCapture() {
        XCTAssertTrue(
            PasswordCapturePolicy.captureIsAllowed(isPrivateWindow: false, isEphemeralTab: false))
    }

    func testFirstPasswordForAUsernameIsAPlainSave() {
        let captured = CapturedFormCredential(domain: "example.com", username: "alice", password: "s3cret")
        XCTAssertEqual(PasswordCapturePolicy.outcome(for: captured, existing: []), .save)
        XCTAssertEqual(
            PasswordCapturePolicy.outcome(
                for: captured,
                existing: [WebCredential(domain: "example.com", username: "bob", password: "other")]
            ),
            .save
        )
    }

    func testUnchangedLoginDoesNotPrompt() {
        let captured = CapturedFormCredential(domain: "example.com", username: "alice", password: "s3cret")
        XCTAssertEqual(
            PasswordCapturePolicy.outcome(
                for: captured,
                existing: [WebCredential(domain: "example.com", username: "alice", password: "s3cret")]
            ),
            .alreadyStored
        )
    }

    /// The destructive case: confirming replaces a stored password. It must be
    /// distinguishable from a first-time save so the prompt can say so.
    func testDifferentPasswordForAStoredUsernameIsAnUpdate() {
        let captured = CapturedFormCredential(domain: "example.com", username: "alice", password: "typo")
        XCTAssertEqual(
            PasswordCapturePolicy.outcome(
                for: captured,
                existing: [WebCredential(domain: "example.com", username: "alice", password: "s3cret")]
            ),
            .update
        )
    }
}

final class PasswordCaptureThrottleTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    /// A page can post in a loop with no user gesture; each admitted message
    /// costs a synchronous main-thread keychain query.
    func testRefusesABurstFromTheSameOrigin() {
        var throttle = PasswordCaptureThrottle()
        XCTAssertTrue(throttle.admit(origin: "evil.com", now: start))
        for i in 1...1000 {
            let now = start.addingTimeInterval(Double(i) * 0.0005)
            XCTAssertFalse(throttle.admit(origin: "evil.com", now: now))
        }
    }

    func testAdmitsAgainAfterTheInterval() {
        var throttle = PasswordCaptureThrottle()
        XCTAssertTrue(throttle.admit(origin: "example.com", now: start))
        XCTAssertFalse(
            throttle.admit(origin: "example.com", now: start.addingTimeInterval(0.9)))
        XCTAssertTrue(
            throttle.admit(origin: "example.com", now: start.addingTimeInterval(1.1)))
    }

    /// One outstanding sheet at a time: sheets are window-modal, so a queue of
    /// them makes the window unusable.
    func testRefusesEverythingWhileAPromptIsOutstanding() {
        var throttle = PasswordCaptureThrottle()
        XCTAssertTrue(throttle.admit(origin: "example.com", now: start))
        throttle.promptDidBegin()
        XCTAssertFalse(throttle.admit(origin: "other.com", now: start.addingTimeInterval(10)))
        throttle.promptDidEnd()
        XCTAssertTrue(throttle.admit(origin: "other.com", now: start.addingTimeInterval(11)))
    }

    /// Origins are independent: one noisy site must not mute a real login
    /// elsewhere.
    func testDistinctOriginsAreTrackedSeparately() {
        var throttle = PasswordCaptureThrottle()
        XCTAssertTrue(throttle.admit(origin: "a.example", now: start))
        XCTAssertTrue(throttle.admit(origin: "b.example", now: start))
        XCTAssertFalse(throttle.admit(origin: "a.example", now: start))
    }

    /// Origin keys come from pages, so the table must not grow without bound
    /// as a page navigates across hosts.
    func testStaleOriginsArePruned() {
        var throttle = PasswordCaptureThrottle()
        for i in 0..<500 {
            // Two seconds apart: by the next admission each earlier entry is
            // stale and can no longer refuse anything.
            XCTAssertTrue(throttle.admit(origin: "host-\(i).example", now: start.addingTimeInterval(Double(i) * 2)))
        }
        XCTAssertLessThan(throttle.trackedOriginCount, 100)
    }
}
