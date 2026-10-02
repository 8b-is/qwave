import AppKit
import Persistence

/// Applies the user's theme choice to the app chrome.
///
/// `.system` clears the override (windows follow macOS), a forced `.light` /
/// `.dark` sets it app-wide. Private windows keep their always-dark override
/// (BrowserWindowController sets `.darkAqua` on those regardless — a private
/// window looking like a normal one would be its own kind of leak).
@MainActor
final class ThemeController {
    private let settings: SettingsStore
    /// NotificationCenter token; only touched on the main actor except the
    /// teardown in `deinit`, which cannot be isolated.
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    init(settings: SettingsStore) {
        self.settings = settings
        // SettingsStore is a plain UserDefaults wrapper, not observable, so
        // the controller listens to the defaults domain directly and re-applies
        // only when the theme key changes.
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.apply()
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Pushes the stored theme mode onto `NSApp.appearance`. Idempotent —
    /// called at launch and on every settings change.
    func apply() {
        NSApp.appearance = settings.themeMode.nsAppearance
    }
}

extension ThemeMode {
    /// The AppKit appearance for this mode; nil means "follow the system".
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}
