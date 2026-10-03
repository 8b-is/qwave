import AppKit
import Foundation
import QwaveSupport

// NOTE: no file-scope @MainActor globals live here. A @MainActor class
// constructed in a file-scope initializer runs before the main-actor
// executor is in service and breaks the first delegate callback's executor
// check (SIGSEGV in swift_task_isMainExecutorImpl — the launch crash).
// Launch-time work is wired in AppDelegate.applicationDidFinishLaunching,
// where the executor is real.

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
