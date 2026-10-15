import AppKit
#if !QWAVE_APP_STORE
    import Sparkle
#endif

/// Direct releases use Sparkle; Apple distributes store updates.
@MainActor
final class QwaveUpdater: NSObject, NSMenuItemValidation {
    #if !QWAVE_APP_STORE
        private let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    #endif

    var supportsUpdates: Bool {
        #if QWAVE_APP_STORE
            false
        #else
            true
        #endif
    }

    var automaticallyChecksForUpdates: Bool {
        get {
            #if QWAVE_APP_STORE
                false
            #else
                controller.updater.automaticallyChecksForUpdates
            #endif
        }
        set {
            #if !QWAVE_APP_STORE
                controller.updater.automaticallyChecksForUpdates = newValue
            #endif
        }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        #if !QWAVE_APP_STORE
            controller.checkForUpdates(sender)
        #endif
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        #if QWAVE_APP_STORE
            false
        #else
            controller.updater.canCheckForUpdates
        #endif
    }
}
