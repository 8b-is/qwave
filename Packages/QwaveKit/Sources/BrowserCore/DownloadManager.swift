import Foundation
import WebKit
import Combine
import QwaveSupport

public struct DownloadItem: Identifiable, Equatable {
    public enum State: Equatable {
        case inProgress
        case finished
        case failed(String)
        case cancelled
    }

    public let id: UUID
    public var filename: String
    public var destination: URL?
    public var state: State
    public var startedAt: Date
    /// Live progress in [0, 1]; stays 0 until the first `Progress` tick.
    public var fractionCompleted: Double
    /// Bytes written so far, and the expected total (0 when unknown).
    public var completedBytes: Int64
    public var totalBytes: Int64
    /// The request the download came from — used to retry a failed/cancelled item.
    public var sourceURL: URL?

    public init(
        id: UUID = UUID(),
        filename: String,
        destination: URL?,
        state: State,
        startedAt: Date = Date(),
        fractionCompleted: Double = 0,
        completedBytes: Int64 = 0,
        totalBytes: Int64 = 0,
        sourceURL: URL? = nil
    ) {
        self.id = id
        self.filename = filename
        self.destination = destination
        self.state = state
        self.startedAt = startedAt
        self.fractionCompleted = fractionCompleted
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.sourceURL = sourceURL
    }
}

/// Tracks `WKDownload`s, writing into ~/Downloads with collision-free names.
@MainActor
public final class DownloadManager: NSObject, ObservableObject {
    @Published public private(set) var items: [DownloadItem] = []

    private var itemIDs: [ObjectIdentifier: UUID] = [:]
    private var activeDownloads: [ObjectIdentifier: WKDownload] = [:]
    private var progressObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private let directory: URL

    public init(directory: URL? = nil) {
        self.directory =
            directory
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        super.init()
    }

    public func track(_ download: WKDownload) {
        download.delegate = self
        let key = ObjectIdentifier(download)
        let item = DownloadItem(
            filename: "download",
            destination: nil,
            state: .inProgress,
            sourceURL: download.originalRequest?.url
        )
        itemIDs[key] = item.id
        activeDownloads[key] = download
        items.insert(item, at: 0)
        observeProgress(of: download, itemID: item.id)
    }

    public func cancel(itemID: UUID) {
        guard let key = itemIDs.first(where: { $0.value == itemID })?.key,
            let download = activeDownloads[key]
        else { return }
        download.cancel { _ in }
        stopObserving(key: key)
        activeDownloads.removeValue(forKey: key)
        update(itemID: itemID) { $0.state = .cancelled }
    }

    /// Restarts a failed or cancelled download from its original URL. A web view
    /// is needed to drive the new `WKDownload`; the old row is replaced.
    public func retry(itemID: UUID, using webView: WKWebView) {
        guard let index = items.firstIndex(where: { $0.id == itemID }),
            let url = items[index].sourceURL
        else { return }
        remove(itemID: itemID)
        webView.startDownload(using: URLRequest(url: url)) { [weak self] download in
            self?.track(download)
        }
    }

    /// Drops finished, failed, and cancelled rows; in-progress downloads stay.
    public func clearFinished() {
        let removed = Set(items.filter { $0.state != .inProgress }.map(\.id))
        items.removeAll { removed.contains($0.id) }
        itemIDs = itemIDs.filter { !removed.contains($0.value) }
    }

    private func remove(itemID: UUID) {
        if let key = itemIDs.first(where: { $0.value == itemID })?.key {
            stopObserving(key: key)
            activeDownloads.removeValue(forKey: key)
            itemIDs.removeValue(forKey: key)
        }
        items.removeAll { $0.id == itemID }
    }

    private func observeProgress(of download: WKDownload, itemID: UUID) {
        let key = ObjectIdentifier(download)
        progressObservations[key] = download.progress.observe(
            \.fractionCompleted, options: [.initial, .new]
        ) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            let completed = progress.completedUnitCount
            let total = progress.totalUnitCount
            Task { @MainActor in
                self?.update(itemID: itemID) {
                    $0.fractionCompleted = fraction
                    $0.completedBytes = completed
                    $0.totalBytes = max(total, 0)
                }
            }
        }
    }

    private func stopObserving(key: ObjectIdentifier) {
        progressObservations[key]?.invalidate()
        progressObservations.removeValue(forKey: key)
    }

    public var hasActiveDownloads: Bool {
        items.contains { $0.state == .inProgress }
    }

    private func update(itemID: UUID, _ mutate: (inout DownloadItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        mutate(&items[index])
    }

    private func uniqueDestination(for filename: String) -> URL {
        Self.collisionFreeURL(for: filename, in: directory)
    }

    /// Finder-style collision-free URL: `name.ext`, then `name (2).ext`,
    /// `name (3).ext`, … skipping any path that already exists.
    nonisolated static func collisionFreeURL(
        for filename: String,
        in directory: URL,
        fileManager: FileManager = .default
    ) -> URL {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = directory.appendingPathComponent(filename)
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            candidate = directory.appendingPathComponent(numbered)
            counter += 1
        }
        return candidate
    }
}

extension DownloadManager: WKDownloadDelegate {
    public func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        // Swift 6 / macOS 26 SDK types this closure @MainActor @Sendable; match it
        // exactly or the WKDownloadDelegate conformance is not satisfied.
        completionHandler: @escaping @MainActor @Sendable (URL?) -> Void
    ) {
        let destination = uniqueDestination(for: suggestedFilename)
        if let itemID = itemIDs[ObjectIdentifier(download)] {
            update(itemID: itemID) {
                $0.filename = destination.lastPathComponent
                $0.destination = destination
            }
        }
        completionHandler(destination)
    }

    public func downloadDidFinish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        if let itemID = itemIDs[key] {
            update(itemID: itemID) {
                $0.state = .finished
                $0.fractionCompleted = 1
            }
        }
        stopObserving(key: key)
        activeDownloads.removeValue(forKey: key)
        QwaveLog.browser.info("Download finished")
    }

    public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let key = ObjectIdentifier(download)
        if let itemID = itemIDs[key] {
            update(itemID: itemID) { $0.state = .failed(error.localizedDescription) }
        }
        stopObserving(key: key)
        activeDownloads.removeValue(forKey: key)
    }
}
