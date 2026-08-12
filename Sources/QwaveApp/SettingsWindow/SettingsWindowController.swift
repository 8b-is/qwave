import AppKit
import SwiftUI

final class SettingsWindowController: NSWindowController {
    init(environment: BrowserEnvironment) {
        let hosting = NSHostingController(rootView: SettingsRootView(environment: environment))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Qwave Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 720, height: 520))
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not supported")
    }
}
