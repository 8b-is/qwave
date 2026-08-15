import AppKit
import Foundation
import QwaveSupport

/// One-shot Spotlight sweep at launch. File-scope globals are never released,
/// so the observer survives for the whole process lifetime.
let spotlightLaunchSync = SpotlightLaunchSync()

// Runtime egress enforcement (issue #77): before anything else runs, install
// EgressGuard as a process-wide URLProtocol so every default- or
// shared-configuration URLSession request is checked against
// EgressAllowlist before it reaches the network. This alone does not reach a
// custom-configuration session (ephemeral, pinned, etc.) — those opt in
// individually via EgressGuard.install(into:); see EgressGuard's doc comment
// for the full scope and its deliberate exclusions.
URLProtocol.registerClass(EgressGuard.self)

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
