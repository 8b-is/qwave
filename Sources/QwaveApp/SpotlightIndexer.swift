import AppKit
import CoreSpotlight
import Foundation
import Persistence
import QwaveSupport
import UniformTypeIdentifiers

/// Syncs Qwave bookmarks into Spotlight so they can be opened with Command+Space.
///
/// Design notes:
/// - Bookmarks are indexed live when created (see
///   `BrowserWindowController.addBookmark`).
/// - A full sweep runs once per launch (`SpotlightLaunchSync`, wired in
///   `main.swift`). The sweep deletes everything and re-adds, which also
///   removes entries for bookmarks deleted or renamed while the app was closed.
/// - Indexing is best-effort: a CoreSpotlight failure must never block the UI
///   path that created the bookmark, so failures are logged, not thrown.
enum SpotlightIndexer {
    static let domainIdentifier = "is.8b.qwave.bookmarks"

    /// Indexes one newly created bookmark.
    @MainActor
    static func index(_ bookmark: Bookmark) async {
        do {
            try await CSSearchableIndex.default().indexSearchableItems([item(for: bookmark)])
        } catch {
            QwaveLog.browser.info(
                "Spotlight: failed to index bookmark '\(bookmark.title, privacy: .public)'"
            )
        }
    }

    /// Replaces the whole Spotlight index with the current bookmark set.
    /// Call sparingly: delete-all + re-add is not free.
    @MainActor
    static func reindexAll(_ bookmarks: [Bookmark]) async {
        let index = CSSearchableIndex.default()
        do {
            try await index.deleteAllSearchableItems()
            try await index.indexSearchableItems(bookmarks.map(item(for:)))
        } catch {
            QwaveLog.browser.info("Spotlight: launch reindex failed (\(String(describing: error)))")
        }
    }

    private static func item(for bookmark: Bookmark) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .url)
        attributes.title = bookmark.title
        attributes.displayName = bookmark.title
        attributes.contentURL = bookmark.url
        attributes.contentDescription = bookmark.folder.map { "Bookmark · \($0)" } ?? "Bookmark"
        attributes.keywords = [bookmark.url.host].compactMap { $0 }
        return CSSearchableItem(
            uniqueIdentifier: "bookmark-\(bookmark.id)",
            domainIdentifier: domainIdentifier,
            attributeSet: attributes
        )
    }
}

/// One-shot launch sweep that keeps the on-device index in sync with the
/// bookmark table (including deletions made while the app was closed).
///
/// Kept alive for the process lifetime by a file-scope global in `main.swift`.
@MainActor
final class SpotlightLaunchSync {
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.reindexWhenReady()
            }
        }
    }

    private func reindexWhenReady() async {
        // BrowserEnvironment is built asynchronously after the launch
        // notification; wait briefly instead of racing it.
        let delegate = NSApp.delegate as? AppDelegate
        var attempts = 0
        while delegate?.environment?.bookmarks == nil, attempts < 50 {
            try? await Task.sleep(for: .milliseconds(100))
            attempts += 1
        }
        guard let bookmarks = delegate?.environment?.bookmarks else {
            QwaveLog.browser.info("Spotlight: launch reindex skipped (no bookmark store)")
            return
        }
        do {
            let all = try await bookmarks.all()
            await SpotlightIndexer.reindexAll(all)
        } catch {
            QwaveLog.browser.info("Spotlight: launch reindex failed (\(String(describing: error)))")
        }
    }
}
