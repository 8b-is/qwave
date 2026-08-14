import AppKit

/// One-shot Spotlight sweep at launch. File-scope globals are never released,
/// so the observer survives for the whole process lifetime.
let spotlightLaunchSync = SpotlightLaunchSync()

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
