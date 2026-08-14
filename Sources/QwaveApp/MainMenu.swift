import Summarize
import AppKit
import Sparkle

/// Programmatic main menu. Actions dispatch through the responder chain; tab
/// and navigation actions land on `BrowserWindowController`, app-level ones
/// on `AppDelegate`.
@MainActor
enum MainMenu {
    /// Held so the AppDelegate can hide the whole Summarize menu when the
    /// model is unavailable (vanish-cleanly: no grey-out, no empty menu).
    static var summarizeTopLevelItem: NSMenuItem?
    static func build(updater: SPUStandardUpdaterController) -> NSMenu {
        let main = NSMenu()

        // App
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(
            withTitle: "About Qwave", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
        appMenu.addItem(.separator())
        // Sparkle enables/disables this item itself via SPUUpdater.canCheckForUpdates.
        let checkForUpdates = appMenu.addItem(
            withTitle: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: "")
        checkForUpdates.target = updater
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        // Title + enabled state are set in AppDelegate.validateMenuItem based on
        // whether Qwave is already the default browser.
        appMenu.addItem(
            withTitle: "Set Qwave as Default Browser…",
            action: #selector(AppDelegate.makeDefaultBrowser(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let servicesItem = appMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = NSMenu()
        NSApp.servicesMenu = servicesItem.submenu
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Qwave", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(
            withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(
            withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Qwave", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File
        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        fileMenu.addItem(
            withTitle: "New Tab", action: #selector(BrowserWindowController.newTab(_:)), keyEquivalent: "t")
        let ephemeral = fileMenu.addItem(
            withTitle: "New Ephemeral Tab", action: #selector(BrowserWindowController.newEphemeralTab(_:)),
            keyEquivalent: "t")
        ephemeral.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(withTitle: "New Window", action: #selector(AppDelegate.newWindow(_:)), keyEquivalent: "n")
        let privateWindow = fileMenu.addItem(
            withTitle: "New Private Window", action: #selector(AppDelegate.newPrivateWindow(_:)), keyEquivalent: "n")
        privateWindow.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(.separator())
        fileMenu.addItem(
            withTitle: "Open…", action: #selector(BrowserWindowController.openDocument(_:)), keyEquivalent: "o")
        fileMenu.addItem(
            withTitle: "Open Location…", action: #selector(BrowserWindowController.openLocation(_:)), keyEquivalent: "l"
        )
        fileMenu.addItem(.separator())
        fileMenu.addItem(
            withTitle: "Close Tab", action: #selector(BrowserWindowController.closeTab(_:)), keyEquivalent: "w")
        let closeWindow = fileMenu.addItem(
            withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeWindow.keyEquivalentModifierMask = [.command, .shift]

        // Edit
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: "Find…", action: #selector(BrowserWindowController.showFindBar(_:)), keyEquivalent: "f")
        editMenu.addItem(
            withTitle: "Find Next", action: #selector(BrowserWindowController.findNext(_:)), keyEquivalent: "g")
        let findPrev = editMenu.addItem(
            withTitle: "Find Previous", action: #selector(BrowserWindowController.findPrevious(_:)), keyEquivalent: "g")
        findPrev.keyEquivalentModifierMask = [.command, .shift]

        // View
        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        viewMenu.addItem(
            withTitle: "Reload Page", action: #selector(BrowserWindowController.reload(_:)), keyEquivalent: "r")
        viewMenu.addItem(
            withTitle: "Stop Loading", action: #selector(BrowserWindowController.stopLoading(_:)), keyEquivalent: ".")
        viewMenu.addItem(.separator())
        viewMenu.addItem(
            withTitle: "Actual Size", action: #selector(BrowserWindowController.actualSize(_:)), keyEquivalent: "0")
        viewMenu.addItem(
            withTitle: "Zoom In", action: #selector(BrowserWindowController.zoomIn(_:)), keyEquivalent: "+")
        viewMenu.addItem(
            withTitle: "Zoom Out", action: #selector(BrowserWindowController.zoomOut(_:)), keyEquivalent: "-")
        viewMenu.addItem(.separator())
        let fullScreen = viewMenu.addItem(
            withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]

        // History
        let historyItem = NSMenuItem()
        main.addItem(historyItem)
        let historyMenu = NSMenu(title: "History")
        historyItem.submenu = historyMenu
        historyMenu.addItem(
            withTitle: "Back", action: #selector(BrowserWindowController.goBack(_:)), keyEquivalent: "[")
        historyMenu.addItem(
            withTitle: "Forward", action: #selector(BrowserWindowController.goForward(_:)), keyEquivalent: "]")
        historyMenu.addItem(.separator())
        let library = historyMenu.addItem(
            withTitle: "Show History & Bookmarks", action: #selector(AppDelegate.showLibrary(_:)), keyEquivalent: "y")
        library.keyEquivalentModifierMask = [.command]

        // Bookmarks
        let bookmarksItem = NSMenuItem()
        main.addItem(bookmarksItem)
        let bookmarksMenu = NSMenu(title: "Bookmarks")
        bookmarksItem.submenu = bookmarksMenu
        bookmarksMenu.addItem(
            withTitle: "Add Bookmark", action: #selector(BrowserWindowController.addBookmark(_:)), keyEquivalent: "d")

        // Memory Wave — MEM8 substrate; never automatic.
        let memoryItem = NSMenuItem()
        main.addItem(memoryItem)
        let memoryMenu = NSMenu(title: "Memory Wave")
        memoryItem.submenu = memoryMenu
        let remember = memoryMenu.addItem(
            withTitle: "Remember This Page",
            action: #selector(BrowserWindowController.rememberThisPage(_:)), keyEquivalent: "m")
        remember.keyEquivalentModifierMask = [.command, .shift]
        let rememberSel = memoryMenu.addItem(
            withTitle: "Remember Selection",
            action: #selector(BrowserWindowController.rememberSelection(_:)), keyEquivalent: "r")
        rememberSel.keyEquivalentModifierMask = [.command, .shift]
        let summarize = memoryMenu.addItem(
            withTitle: "Summarize Page",
            action: #selector(BrowserWindowController.summarizePage(_:)), keyEquivalent: "s")
        summarize.keyEquivalentModifierMask = [.command, .shift]
        let ask = memoryMenu.addItem(
            withTitle: "Ask Memory Wave…",
            action: #selector(BrowserWindowController.askMemoryWave(_:)), keyEquivalent: "k")
        ask.keyEquivalentModifierMask = [.command, .shift]
        memoryMenu.addItem(.separator())
        memoryMenu.addItem(
            withTitle: "Timeline",
            action: #selector(BrowserWindowController.showTimeline(_:)), keyEquivalent: "")
        memoryMenu.addItem(
            withTitle: "Open Nibble Folder",
            action: #selector(BrowserWindowController.openNibbleFolder(_:)), keyEquivalent: "")
        memoryMenu.addItem(
            withTitle: "Show Memory Wave",
            action: #selector(BrowserWindowController.toggleMemoryWave(_:)), keyEquivalent: "")

        // Tab navigation
        let tabItem = NSMenuItem()
        main.addItem(tabItem)
        let tabMenu = NSMenu(title: "Tab")
        tabItem.submenu = tabMenu
        let nextTab = tabMenu.addItem(
            withTitle: "Show Next Tab", action: #selector(BrowserWindowController.selectNextTab(_:)), keyEquivalent: "]"
        )
        nextTab.keyEquivalentModifierMask = [.command, .shift]
        let prevTab = tabMenu.addItem(
            withTitle: "Show Previous Tab", action: #selector(BrowserWindowController.selectPreviousTab(_:)),
            keyEquivalent: "[")
        prevTab.keyEquivalentModifierMask = [.command, .shift]
        tabMenu.addItem(.separator())
        tabMenu.addItem(
            withTitle: "Pin/Unpin Tab", action: #selector(BrowserWindowController.togglePinTab(_:)), keyEquivalent: "")
        tabMenu.addItem(
            withTitle: "Hibernate Inactive Tabs Now",
            action: #selector(BrowserWindowController.hibernateInactiveTabs(_:)), keyEquivalent: "")

        // Summarize (on-device FoundationModels — docs/SUMMARIZE.md)
        let summarizeItem = NSMenuItem()
        main.addItem(summarizeItem)
        let summarizeMenu = NSMenu(title: "Summarize")
        summarizeItem.submenu = summarizeMenu
        // Vanish-cleanly needs the whole top-level menu hidden when the model
        // is unavailable; the AppDelegate refreshes this on launch/foreground.
        MainMenu.summarizeTopLevelItem = summarizeItem
        // Menu open is explicit user intent: prewarm fires here, never on
        // page load. Measured delta lives in docs/SUMMARIZE.md.
        summarizeMenu.delegate = SummarizeMenuPrewarm.shared
        let summarizeCmd = summarizeMenu.addItem(
            withTitle: "Summarize Page…",
            action: #selector(BrowserWindowController.summarizeThisPage(_:)), keyEquivalent: "s")
        summarizeCmd.keyEquivalentModifierMask = [.command, .option]

        // Window
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(
            withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        return main
    }
}

/// Fires `prewarm` when the Summarize menu opens — explicit user intent,
/// never speculative on page load (docs/SUMMARIZE.md). `NSMenu.delegate` is
/// weak, so this instance is held statically for the menu's lifetime.
@MainActor
final class SummarizeMenuPrewarm: NSObject, NSMenuDelegate {
    static let shared = SummarizeMenuPrewarm()

    func menuWillOpen(_ menu: NSMenu) {
        guard SummarizeSession.availability() == .available else { return }
        SummarizeSession.prewarm()
    }
}
