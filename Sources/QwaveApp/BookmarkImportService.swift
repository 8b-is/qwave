import AppKit
import Persistence
import QwaveSupport

/// On-demand import of bookmarks from another browser.
///
/// Access model: the user picks their browser profile folder (or a `Bookmarks`
/// file directly) through NSOpenPanel. That panel grant is the ONLY file
/// access — no Full Disk Access entitlement, no broad reads. The security-
/// scoped resource is opened only around the single read and closed right
/// after; nothing else on disk is touched, and nothing leaves the device.
@MainActor
enum BookmarkImportService {
    /// Presents the open panel, reads the chosen Chromium `Bookmarks` file, and
    /// inserts any bookmarks not already stored. `reindex` refreshes Spotlight
    /// with the full set once the import finishes.
    static func run(
        into store: BookmarkStore,
        reindex: @escaping @MainActor ([Bookmark]) async -> Void
    ) {
        let panel = NSOpenPanel()
        panel.title = "Import Bookmarks"
        panel.message = "Choose a browser profile folder or its \u{201C}Bookmarks\u{201D} file (Chrome, Edge, Brave)."
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let picked = panel.url else { return }
            Task { @MainActor in
                await importChromium(from: picked, into: store, reindex: reindex)
            }
        }
    }

    private static func importChromium(
        from picked: URL,
        into store: BookmarkStore,
        reindex: @escaping @MainActor ([Bookmark]) async -> Void
    ) async {
        // The panel grant is security-scoped; open it only for the read.
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }

        // Accept either the profile folder or the Bookmarks file itself.
        let file = picked.hasDirectoryPath ? picked.appendingPathComponent("Bookmarks") : picked

        guard
            let data = try? Data(contentsOf: file),
            let parsed = try? BookmarkImporter.parseChromiumJSON(data)
        else {
            QwaveLog.browser.info("Import: no readable Chromium Bookmarks file at chosen location")
            presentResult(imported: nil)
            return
        }

        var inserted = 0
        for item in parsed {
            if let exists = try? await store.contains(url: item.url), exists { continue }
            if (try? await store.add(title: item.title, url: item.url, folder: item.folder)) != nil {
                inserted += 1
            }
        }

        if let all = try? await store.all() {
            await reindex(all)
        }
        presentResult(imported: inserted)
    }

    private static func presentResult(imported: Int?) {
        let alert = NSAlert()
        if let imported {
            alert.messageText = "Import Complete"
            alert.informativeText =
                imported == 0
                ? "No new bookmarks were found to import."
                : "Imported \(imported) bookmark\(imported == 1 ? "" : "s")."
        } else {
            alert.messageText = "Import Failed"
            alert.informativeText =
                "That location doesn\u{2019}t contain a supported Chromium \u{201C}Bookmarks\u{201D} file."
        }
        alert.runModal()
    }
}
