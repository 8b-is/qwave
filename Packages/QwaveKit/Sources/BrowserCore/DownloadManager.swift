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

    public init(id: UUID = UUID(), filename: String, destination: URL?, state: State, startedAt: Date = Date()) {
        self.id = id
        self.filename = filename
        self.destination = destination
        self.state = state
        self.startedAt = startedAt
    }
}

/// Tracks `WKDownload`s, writing into ~/Downloads with collision-free names.
@MainActor
public final class DownloadManager: NSObject, ObservableObject {
    @Published public private(set) var items: [DownloadItem] = []

    private var itemIDs: [ObjectIdentifier: UUID] = [:]
    private var activeDownloads: [ObjectIdentifier: WKDownload] = [:]
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
        let item = DownloadItem(filename: "download", destination: nil, state: .inProgress)
        itemIDs[key] = item.id
        activeDownloads[key] = download
        items.insert(item, at: 0)
    }

    public func cancel(itemID: UUID) {
        guard let key = itemIDs.first(where: { $0.value == itemID })?.key,
            let download = activeDownloads[key]
        else { return }
        download.cancel { _ in }
        update(itemID: itemID) { $0.state = .cancelled }
    }

    public var hasActiveDownloads: Bool {
        items.contains { $0.state == .inProgress }
    }

    private func update(itemID: UUID, _ mutate: (inout DownloadItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        mutate(&items[index])
    }

    private func uniqueDestination(for filename: String) -> URL {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = directory.appendingPathComponent(filename)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
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
        completionHandler: @escaping (URL?) -> Void
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
            update(itemID: itemID) { $0.state = .finished }
        }
        activeDownloads.removeValue(forKey: key)
        QwaveLog.browser.info("Download finished")
    }

    public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let key = ObjectIdentifier(download)
        if let itemID = itemIDs[key] {
            update(itemID: itemID) { $0.state = .failed(error.localizedDescription) }
        }
        activeDownloads.removeValue(forKey: key)
    }
}
