import AppKit
import BrowserCore
import SwiftUI

/// Toolbar downloads popover: live list of active and finished downloads with
/// per-item progress and reveal / open / cancel / retry actions. Anchored to the
/// downloads toolbar button (see `BrowserWindowController`).
struct DownloadsPopoverView: View {
    @ObservedObject var downloads: DownloadManager
    /// Restart a failed/cancelled item — routed to the front tab's web view.
    var onRetry: (UUID) -> Void

    private var hasClearable: Bool {
        downloads.items.contains { $0.state != .inProgress }
    }

    var body: some View {
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
            Image(nsImage: iconImage)
                .resizable()
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
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var iconImage: NSImage {
        if let destination = item.destination, FileManager.default.fileExists(atPath: destination.path) {
            return NSWorkspace.shared.icon(forFile: destination.path)
        }
        return NSImage(systemSymbolName: "arrow.down.doc", accessibilityDescription: nil) ?? NSImage()
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
        NSWorkspace.shared.open(destination)
    }

    private func reveal() {
        guard let destination = item.destination else { return }
        NSWorkspace.shared.activateFileViewerSelecting([destination])
    }
}

// MARK: - Toolbar wiring

extension BrowserWindowController {
    /// Toolbar action: toggle the downloads popover anchored to its button.
    @objc func toggleDownloads(_ sender: Any?) {
        guard let button = downloadsButton else { return }
        if let popover = downloadsPopover, popover.isShown {
            popover.close()
            downloadsPopover = nil
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: DownloadsPopoverView(
                downloads: environment.downloads,
                onRetry: { [weak self] itemID in
                    guard let self, let webView = self.tabManager.selectedTab?.webView else { return }
                    self.environment.downloads.retry(itemID: itemID, using: webView)
                }
            )
        )
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        downloadsPopover = popover
    }
}
