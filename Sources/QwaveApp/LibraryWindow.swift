import AppKit
import SwiftUI
import Persistence

/// History + bookmarks browser.
final class LibraryWindowController: NSWindowController {
    init(environment: BrowserEnvironment, openURL: @escaping (URL) -> Void) {
        let hosting = NSHostingController(
            rootView: LibraryView(
                history: environment.history,
                bookmarks: environment.bookmarks,
                openURL: openURL,
                onBookmarksChanged: { [weak environment] in environment?.invalidateBookmarkCache() }
            )
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "History & Bookmarks"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 640, height: 480))
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not supported")
    }
}

private struct LibraryView: View {
    enum Section: String, CaseIterable, Identifiable {
        case history = "History"
        case bookmarks = "Bookmarks"
        var id: String { rawValue }
    }

    let history: HistoryStore?
    let bookmarks: BookmarkStore?
    let openURL: (URL) -> Void
    /// Notifies the environment to drop its cached bookmark set after a delete.
    let onBookmarksChanged: () -> Void

    @State private var section: Section = .history
    @State private var searchText = ""
    @State private var historyEntries: [HistoryEntry] = []
    @State private var bookmarkEntries: [Bookmark] = []

    var body: some View {
        VStack(spacing: 8) {
            Picker("", selection: $section) {
                ForEach(Section.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            TextField("Search", text: $searchText)
                .textFieldStyle(.roundedBorder)

            switch section {
            case .history:
                List(historyEntries) { entry in
                    row(
                        title: entry.title.isEmpty ? entry.url.absoluteString : entry.title,
                        subtitle: entry.url.absoluteString,
                        url: entry.url
                    ) {
                        Task { @MainActor in
                            try? await history?.delete(id: entry.id)
                            reload()
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Clear All History", role: .destructive) {
                        Task { @MainActor in
                            try? await history?.deleteAll()
                            reload()
                        }
                    }
                }
            case .bookmarks:
                List(bookmarkEntries) { bookmark in
                    row(title: bookmark.title, subtitle: bookmark.url.absoluteString, url: bookmark.url) {
                        Task { @MainActor in
                            try? await bookmarks?.delete(id: bookmark.id)
                            onBookmarksChanged()
                            reload()
                        }
                    }
                }
            }
        }
        .padding(12)
        .onAppear { reload() }
        .onChange(of: searchText) { _, _ in reload() }
        .onChange(of: section) { _, _ in reload() }
    }

    private func row(
        title: String,
        subtitle: String,
        url: URL,
        onDelete: @escaping () -> Void
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                openURL(url)
            } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.borderless)
            .help("Open in new tab")
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            openURL(url)
        }
    }

    private func reload() {
        Task { @MainActor in
            let query = searchText.isEmpty ? nil : searchText
            historyEntries = (try? await history?.entries(matching: query, limit: 300)) ?? []
            let allBookmarks = (try? await bookmarks?.all()) ?? []
            bookmarkEntries =
                searchText.isEmpty
                ? allBookmarks
                : allBookmarks.filter {
                    $0.title.localizedCaseInsensitiveContains(searchText)
                        || $0.url.absoluteString.localizedCaseInsensitiveContains(searchText)
                }
        }
    }
}
