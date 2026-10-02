#if canImport(AppKit)
import AppKit
#endif
import BrowserCore
import SwiftUI

/// Toolbar downloads popover: live list of active and finished downloads with
/// per-item progress and reveal / open / cancel / retry actions. Anchored to the
/// downloads toolbar button (see `BrowserWindowController`).
public struct DownloadsPopoverView: View {
    @ObservedObject public var downloads: DownloadManager
    /// Restart a failed/cancelled item — routed to the front tab's web view.
    public var onRetry: (UUID) -> Void

    public init(downloads: DownloadManager, onRetry: @escaping (UUID) -> Void) {
        self.downloads = downloads
        self.onRetry = onRetry
    }

    private var hasClearable: Bool {
        downloads.items.contains { $0.state != .inProgress }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "arrow.down.circle")
                Text("Downloads").font(.headline)
                Spacer()
                if hasClearable {
                    Button("Clear") { downloads.clearFinished() }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                }
            }

            if downloads.items.isEmpty {
                Text("No downloads yet.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(downloads.items) { item in
                            DownloadRowView(
                                item: item,
                                onCancel: { downloads.cancel(itemID: item.id) },
                                onRetry: { onRetry(item.id) }
                            )
                        }
                    }
                }
                .frame(minHeight: 80, maxHeight: 320)
            }
        }
        .padding(14)
        .frame(width: 360)
    }
}

private struct DownloadRowView: View {
    let item: DownloadItem
    var onCancel: () -> Void
    var onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            iconView
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.filename)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                subtitle
                if case .inProgress = item.state {
                    progressBar
                }
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(8)
#if canImport(AppKit)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
#else
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(uiColor: .secondarySystemBackground)))
#endif
    }

    /// Resolved file icons keyed by path — a file's icon is stable, so this
    /// avoids a disk stat + NSWorkspace icon fetch on every SwiftUI render
    /// (which re-runs on each progress publish while a download is active).
    @MainActor private static var iconCache: [String: PlatformImage] = [:]

    private var iconView: some View {
        #if canImport(AppKit)
        Image(nsImage: iconImage).resizable()
        #else
        Image(uiImage: iconImage).resizable()
        #endif
    }

    @MainActor private var iconImage: PlatformImage {
        if let destination = item.destination, FileManager.default.fileExists(atPath: destination.path) {
            let path = destination.path
            if let cached = Self.iconCache[path] { return cached }
#if canImport(AppKit)
            let icon = NSWorkspace.shared.icon(forFile: path)
#else
            // iOS has no per-file icon service; the document glyph is the honest stand-in.
            let icon = PlatformImage(systemName: "arrow.down.doc", withConfiguration: nil) ?? PlatformImage()
#endif
            Self.iconCache[path] = icon
            return icon
        }
#if canImport(AppKit)
        return NSImage(systemSymbolName: "arrow.down.doc", accessibilityDescription: nil) ?? NSImage()
#else
        return PlatformImage(systemName: "arrow.down.doc", withConfiguration: nil) ?? PlatformImage()
#endif
    }

    @ViewBuilder private var subtitle: some View {
        switch item.state {
        case .inProgress:
            Text(progressText)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .finished:
            Text(sizeText.isEmpty ? "Completed" : "Completed · \(sizeText)")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        case .cancelled:
            Text("Cancelled")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var progressBar: some View {
        if item.totalBytes > 0 {
            ProgressView(value: min(max(item.fractionCompleted, 0), 1))
                .controlSize(.small)
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }

    @ViewBuilder private var actions: some View {
        switch item.state {
        case .inProgress:
            Button("Cancel", action: onCancel)
                .controlSize(.small)
        case .finished:
            HStack(spacing: 6) {
                Button("Open") { open() }
                    .controlSize(.small)
                Button {
                    reveal()
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .controlSize(.small)
                .help("Reveal in Finder")
            }
        case .failed, .cancelled:
            Button("Retry", action: onRetry)
                .controlSize(.small)
                .disabled(item.sourceURL == nil)
        }
    }

    /// Shared across renders — ByteCountFormatter is costly to allocate and both
    /// text getters re-run on every progress publish.
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private var progressText: String {
        let done = Self.byteFormatter.string(fromByteCount: item.completedBytes)
        if item.totalBytes > 0 {
            let total = Self.byteFormatter.string(fromByteCount: item.totalBytes)
            let percent = Int((min(max(item.fractionCompleted, 0), 1) * 100).rounded())
            return "\(done) of \(total) · \(percent)%"
        }
        return item.completedBytes > 0 ? done : "Downloading…"
    }

    private var sizeText: String {
        guard item.totalBytes > 0 else { return "" }
        return Self.byteFormatter.string(fromByteCount: item.totalBytes)
    }

    private func open() {
        guard let destination = item.destination else { return }
#if canImport(AppKit)
        NSWorkspace.shared.open(destination)
#else
        // iOS: downloads live in the app's sandbox; nothing to hand off yet.
#endif
    }

    private func reveal() {
        guard let destination = item.destination else { return }
#if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting([destination])
#else
        // iOS: no Finder to reveal in; the Files picker wiring is a follow-up.
#endif
    }
}
