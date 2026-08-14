import Foundation

/// Decides what, if anything, a browsing window may advertise over Handoff.
///
/// Handoff mirrors the active page to the user's other devices, so the policy
/// is privacy-first: a private window or an ephemeral tab is never handed off,
/// and only http(s) pages qualify — internal pages (the `qwave://` start page),
/// `file://` documents, and any other scheme are suppressed. Keeping this a
/// pure function lets the window controller stay a thin lifecycle owner and
/// lets the rules be unit-tested without AppKit.
public enum HandoffPolicy {
    /// The URL to advertise via `NSUserActivityTypeBrowsingWeb`, or `nil` when
    /// Handoff must be suppressed for this context.
    public static func webpageURL(
        url: URL?,
        isPrivateWindow: Bool,
        isEphemeralTab: Bool
    ) -> URL? {
        guard !isPrivateWindow, !isEphemeralTab, let url else { return nil }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }
}
