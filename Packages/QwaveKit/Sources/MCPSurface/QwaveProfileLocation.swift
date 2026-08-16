import Foundation

/// Where Qwave's on-disk state lives, from the point of view of a process that
/// is *not* the browser.
///
/// This mirrors `BrowserEnvironment.supportDirectory` in the app target. It is
/// duplicated rather than shared because `qwave-mcp` must not link the app —
/// but the two must agree, so `QwaveProfileLocationTests` asserts the literal.
///
/// Qwave is not sandboxed (no `com.apple.security.app-sandbox` in
/// `project.yml`), so this resolves to
/// `~/Library/Application Support/Qwave` for both processes.
public struct QwaveProfileLocation: Sendable, Equatable {
    /// The application-support directory holding `browser.db`, `session.json`,
    /// `containers.json`, …
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The default profile for the current user.
    public static var `default`: QwaveProfileLocation {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return QwaveProfileLocation(directory: base.appendingPathComponent("Qwave", isDirectory: true))
    }

    /// SQLite database holding `history`, `bookmarks` and `favicons`.
    public var browserDatabase: URL { directory.appendingPathComponent("browser.db") }

    /// The autosaved window/tab topology written by `SessionAutosaver`.
    public var sessionSnapshot: URL { directory.appendingPathComponent("session.json") }

    /// The bundle identifier whose `UserDefaults` domain the app writes its
    /// settings into. A separate process must name it explicitly.
    public static let applicationDefaultsSuite = "is.8b.qwave"

    /// Environment variable naming an alternative profile directory.
    public static let profileDirectoryVariable = "QWAVE_MCP_PROFILE_DIR"

    /// The profile this process should read.
    ///
    /// `QWAVE_MCP_PROFILE_DIR` redirects the reader — needed to exercise the
    /// binary against a scratch profile without going anywhere near the user's
    /// real browsing data, and to read an archived profile.
    ///
    /// It redirects **only the reader**. The opt-in gate always reads the app's
    /// own defaults domain, so setting this cannot turn the surface on, and
    /// pointing it at a directory of your own choosing buys you nothing you did
    /// not already have.
    public static func resolved(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> QwaveProfileLocation {
        guard let path = environment[profileDirectoryVariable], !path.isEmpty else { return .default }
        return QwaveProfileLocation(directory: URL(fileURLWithPath: path, isDirectory: true))
    }
}
