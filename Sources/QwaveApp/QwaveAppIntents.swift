import AppIntents
import AppKit
import BrowserCore
import Foundation

// MARK: - Intent error

/// Errors surfaced to Shortcuts/Siri when an intent cannot run.
enum QwaveIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case appNotReady
    case invalidHost
    case unsupportedURL

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appNotReady:
            LocalizedStringResource("Qwave is still starting up. Try again in a moment.")
        case .invalidHost:
            LocalizedStringResource("Give me a website like example.com.")
        case .unsupportedURL:
            LocalizedStringResource("Qwave can only open http:// and https:// web addresses.")
        }
    }
}

// MARK: - Shared host

/// Bridges App Intents to the live app state.
///
/// App Intents run inside the app process (launching it if needed), so
/// `NSApp.delegate` is the entry point once `applicationDidFinishLaunching`
/// has populated `AppDelegate.environment`.
@MainActor
enum QwaveIntentHost {
    static var delegate: AppDelegate? {
        NSApp.delegate as? AppDelegate
    }

    static func requireEnvironment() throws -> BrowserEnvironment {
        guard let environment = delegate?.environment else {
            throw QwaveIntentError.appNotReady
        }
        return environment
    }

    /// Opens a URL in a new tab, creating a window first when the app has none.
    static func open(url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw QwaveIntentError.unsupportedURL
        }
        let window = delegate?.frontmostBrowserWindow ?? delegate?.openWindow()
        window?.openNewTab(url: url)
    }

    /// Applies a resolved Focus decision to the live app: switches the active
    /// window into the mapped container (opening one if the app has none) and
    /// tightens Shields when the filter asks for it.
    static func applyFocus(_ decision: FocusContainerDecision) throws {
        let environment = try requireEnvironment()
        let window = delegate?.frontmostBrowserWindow ?? delegate?.openWindow()
        if decision.makeEphemeral {
            window?.openNewTab(url: nil, ephemeral: true, activate: true)
        } else if let id = decision.switchToContainerID {
            window?.openNewTab(url: nil, containerID: id, ephemeral: false, activate: true)
        }
        window?.window?.makeKeyAndOrderFront(nil)
        if decision.tightenShields {
            environment.shieldsPolicy.defaultAdsBlocked = true
            environment.shieldsPolicy.defaultHTTPSFirst = true
        }
    }
}

// MARK: - Open URL

/// Shortcuts/Siri: "Open <URL> in Qwave".
struct OpenURLIntent: AppIntent {
    static let title: LocalizedStringResource = LocalizedStringResource("Open URL in Qwave")
    static let description = IntentDescription(
        "Opens a web address in a new Qwave tab. Use it from Share menus, automations, or by asking Siri.",
        categoryName: "Navigation"
    )
    static let openAppWhenRun = true

    @Parameter(
        title: "URL",
        description: "The web address to open (http:// or https://).",
        requestValueDialog: IntentDialog("What web address should I open?")
    )
    var url: URL

    @MainActor
    func perform() async throws -> some IntentResult {
        try QwaveIntentHost.open(url: url)
        return .result()
    }
}

// MARK: - New Tab

/// Shortcuts/Siri: "New Qwave tab".
struct NewTabIntent: AppIntent {
    static let title: LocalizedStringResource = LocalizedStringResource("New Tab")
    static let description = IntentDescription(
        "Opens a new tab in the frontmost Qwave window.",
        categoryName: "Navigation"
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let delegate = QwaveIntentHost.delegate else {
            throw QwaveIntentError.appNotReady
        }
        let window = delegate.frontmostBrowserWindow ?? delegate.openWindow()
        window.openNewTab(url: nil)
        return .result()
    }
}

// MARK: - Toggle Shields

/// Shortcuts/Siri: turn ad/tracker blocking on or off for one host.
struct ToggleShieldsIntent: AppIntent {
    static let title: LocalizedStringResource = LocalizedStringResource("Toggle Shields for a Website")
    static let description = IntentDescription(
        "Turns ad and tracker blocking on or off for a specific website (for example: example.com).",
        categoryName: "Privacy"
    )
    static let openAppWhenRun = true

    @Parameter(
        title: "Website",
        description: "The host to change, without the scheme (example.com).",
        requestValueDialog: IntentDialog("For which website?")
    )
    var host: String

    @Parameter(title: "Block ads and trackers", default: true)
    var block: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        let environment = try QwaveIntentHost.requireEnvironment()
        let policy = environment.shieldsPolicy
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            throw QwaveIntentError.invalidHost
        }
        var override = policy.override(forHost: host)
        // Writing an override that matches the global default changes nothing;
        // skip it so shields.json stays free of no-op entries.
        if override.isEmpty, block == policy.defaultAdsBlocked {
            return .result()
        }
        override.adsBlocked = block
        policy.setOverride(override, forHost: host)
        return .result()
    }
}

// MARK: - VPN

/// Shortcuts/Siri: "Connect Qwave VPN".
struct ConnectVPNIntent: AppIntent {
    static let title: LocalizedStringResource = LocalizedStringResource("Connect to VPN")
    static let description = IntentDescription(
        "Connects Qwave to your Mullvad relay.",
        categoryName: "Privacy"
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        let environment = try QwaveIntentHost.requireEnvironment()
        await environment.vpn.connect()
        return .result()
    }
}

/// Shortcuts/Siri: "Disconnect Qwave VPN".
struct DisconnectVPNIntent: AppIntent {
    static let title: LocalizedStringResource = LocalizedStringResource("Disconnect VPN")
    static let description = IntentDescription(
        "Disconnects Qwave from the VPN.",
        categoryName: "Privacy"
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        let environment = try QwaveIntentHost.requireEnvironment()
        environment.vpn.disconnect()
        return .result()
    }
}

// MARK: - Shortcuts catalog

/// Registers the intents in the Shortcuts app (macOS 14+). App Intents are
/// discovered by the system automatically; no Info.plist keys are required.
///
/// Two utterance rules are enforced at build time by
/// `ExtractAppIntentsMetadata`: every phrase must interpolate
/// `\(.applicationName)` exactly once, and only `AppEntity`/`AppEnum`
/// parameters may be interpolated. `URL`, `String`, and `Bool` parameters
/// therefore stay out of the phrases and are collected by Siri through each
/// parameter's `requestValueDialog` instead.
struct QwaveAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenURLIntent(),
            phrases: [
                "Open a URL in \(.applicationName)",
                "Open a web address in \(.applicationName)",
            ],
            shortTitle: "Open in Qwave",
            systemImageName: "globe"
        )
        AppShortcut(
            intent: NewTabIntent(),
            phrases: [
                "New \(.applicationName) tab",
                "Open a new tab in \(.applicationName)",
            ],
            shortTitle: "New Tab",
            systemImageName: "plus.square.on.square"
        )
        AppShortcut(
            intent: ToggleShieldsIntent(),
            phrases: [
                "Change shields for a website in \(.applicationName)",
                "Toggle \(.applicationName) shields for a website",
            ],
            shortTitle: "Toggle Shields",
            systemImageName: "shield"
        )
        AppShortcut(
            intent: ConnectVPNIntent(),
            phrases: [
                "Connect \(.applicationName) VPN",
                "Connect to \(.applicationName) VPN",
            ],
            shortTitle: "Connect VPN",
            systemImageName: "lock.shield"
        )
        AppShortcut(
            intent: DisconnectVPNIntent(),
            phrases: [
                "Disconnect \(.applicationName) VPN",
                "Disconnect from \(.applicationName) VPN",
            ],
            shortTitle: "Disconnect VPN",
            systemImageName: "lock.open"
        )
    }
}
