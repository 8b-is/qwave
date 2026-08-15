import Foundation

/// One filled password input the in-page capture shim saw on a submitted form,
/// in DOM order.
///
/// Value type, no WebKit: the *decision* about which of a form's password
/// fields holds the password worth saving is a rule, so it lives here and is
/// unit-tested, not buried in an injected script string.
public struct CapturedPasswordField: Sendable, Equatable {
    public let value: String
    /// The field's `autocomplete` attribute, verbatim. May carry section
    /// tokens (`section-blue new-password`), so callers match on tokens.
    public let autocomplete: String

    public init(value: String, autocomplete: String = "") {
        self.value = value
        self.autocomplete = autocomplete
    }

    func hasToken(_ token: String) -> Bool {
        autocomplete.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .contains { $0 == token }
    }
}

/// Which of a submitted form's password fields is the password the user now
/// signs in with.
public enum PasswordFieldSelection {
    /// The password to offer to save, or nil when the form is too ambiguous to
    /// guess safely.
    ///
    /// Taking the first password input in DOM order — as the capture shim used
    /// to — saves the *old* secret on a `current / new / confirm` change-password
    /// form, quietly replacing a correct stored password with a stale one. The
    /// rules, in order:
    ///
    /// 1. `autocomplete="new-password"` wins: it is the page stating which
    ///    field the account's password is becoming. If several such fields
    ///    disagree (a mistyped confirmation) nothing is returned — not
    ///    prompting beats storing a password the site never accepted.
    /// 2. Fields the page labelled `current-password` are dropped, as long as
    ///    that leaves something.
    /// 3. Of what remains, the last one wins: an unlabelled change-password
    ///    form ends with the new password, and a plain login form has exactly
    ///    one field, where last and first are the same field.
    public static func submittedPassword(from fields: [CapturedPasswordField]) -> String? {
        let filled = fields.filter { !$0.value.isEmpty }
        guard !filled.isEmpty else { return nil }

        let declaredNew = filled.filter { $0.hasToken("new-password") }
        if !declaredNew.isEmpty {
            let distinct = Set(declaredNew.map(\.value))
            return distinct.count == 1 ? declaredNew[0].value : nil
        }

        let notCurrent = filled.filter { !$0.hasToken("current-password") }
        return (notCurrent.isEmpty ? filled : notCurrent).last?.value
    }

    /// Decode the `passwords` array of the capture shim's payload.
    static func fields(json: [String: Any]) -> [CapturedPasswordField] {
        guard let raw = json["passwords"] as? [[String: Any]] else { return [] }
        return raw.compactMap { entry in
            guard let value = entry["value"] as? String else { return nil }
            return CapturedPasswordField(value: value, autocomplete: entry["autocomplete"] as? String ?? "")
        }
    }
}

/// What the capture prompt should do about a login the page just submitted,
/// given what the store already holds for that domain.
public enum PasswordCaptureOutcome: Sendable, Equatable {
    /// This exact login is already stored — say nothing.
    case alreadyStored
    /// Nothing is stored for this username on this domain.
    case save
    /// A *different* password is stored for this username on this domain, so
    /// confirming the prompt overwrites it. The prompt has to say so: the
    /// destructive case used to be worded exactly like a first-time save, so a
    /// typo'd password on a failed sign-in silently replaced the right one.
    case update
}

/// The rules governing when a submitted password may be captured at all, and
/// what the resulting prompt means. Pure, so both are unit-tested here rather
/// than only being observable by driving an `NSAlert`.
public enum PasswordCapturePolicy {
    /// Whether a tab may capture logins at all.
    ///
    /// Ephemerality is a property of the *tab*, not only of the window: a
    /// normal window can hold an ephemeral tab (Cmd-Opt-T). Gating on the
    /// window alone let those tabs persist a login to the keychain, which is
    /// precisely what an ephemeral tab promises not to do.
    public static func captureIsAllowed(isPrivateWindow: Bool, isEphemeralTab: Bool) -> Bool {
        !isPrivateWindow && !isEphemeralTab
    }

    /// - Parameter existing: what the store returned for `captured.domain`.
    public static func outcome(
        for captured: CapturedFormCredential,
        existing: [WebCredential]
    ) -> PasswordCaptureOutcome {
        guard let stored = existing.first(where: { $0.username == captured.username }) else {
            return .save
        }
        return stored.password == captured.password ? .alreadyStored : .update
    }
}

/// Bounds how often a page can drive the capture path.
///
/// `window.webkit.messageHandlers.<name>.postMessage` is callable from page JS
/// with no user gesture, and every accepted message costs a synchronous
/// keychain query on the main thread and can queue a window-modal sheet. A
/// loop posting thousands of messages would otherwise wedge the window behind
/// a stack of sheets. Two limits: at most one outstanding prompt, and at most
/// one accepted message per origin per ``minimumInterval``.
public struct PasswordCaptureThrottle: Sendable {
    /// A human submitting a login form cannot beat this; a script trivially can.
    public static let minimumInterval: TimeInterval = 1

    /// Past this many tracked origins, entries older than the interval — which
    /// can no longer refuse anything — are dropped, so a page that navigates
    /// across many hosts cannot grow this without bound.
    private static let pruneThreshold = 64

    private var lastAdmitted: [String: Date] = [:]
    private var promptIsOutstanding = false

    public init() {}

    /// How many origins the throttle is still holding state for. Internal so
    /// the pruning above is testable.
    var trackedOriginCount: Int { lastAdmitted.count }

    /// Whether a message from `origin` should be processed. Records the
    /// admission, so callers must ask exactly once per message.
    public mutating func admit(origin: String, now: Date = Date()) -> Bool {
        guard !promptIsOutstanding else { return false }
        if let last = lastAdmitted[origin], now.timeIntervalSince(last) < Self.minimumInterval {
            return false
        }
        if lastAdmitted.count >= Self.pruneThreshold {
            lastAdmitted = lastAdmitted.filter { now.timeIntervalSince($0.value) < Self.minimumInterval }
        }
        lastAdmitted[origin] = now
        return true
    }

    public mutating func promptDidBegin() { promptIsOutstanding = true }
    public mutating func promptDidEnd() { promptIsOutstanding = false }
}
