import CryptoKit
import Darwin
import Foundation

public enum LocalReadingAssetError: Error, Equatable, Sendable {
    case invalidSource
    case invalidStore
    case integrityMismatch
}

/// Verified, app-owned copies. The host must never edit these files in place.
public struct LocalReadingModelAssets: Sendable {
    public let modelURL: URL
    public let tokenizerURL: URL
}

/// Imports user-selected files without downloading weights or running inference.
/// Disk work shares the native reading worker: concurrent imports/inference fail
/// busy instead of queuing. The source files and their permissions are untouched.
public enum LocalReadingModelStore {
    struct Asset: Sendable {
        let filename: String
        let bytes: Int
        let sha256: String
    }

    static let model = Asset(
        filename: "model.gguf", bytes: 730_895_168,
        sha256: "b1b3de114215d9507409a662a501a631095a479a419584e8a2ded6304b19b4f5")
    static let tokenizer = Asset(
        filename: "tokenizer.json", bytes: 4_733_389,
        sha256: "df1d8d5ec5d091b460562ffd545e4a5e91d17d4a0db7ebe733be34ed374377bd")

    /// LFM2.5-1.2B-Instruct Q4_K_M and its canonical tokenizer, under their
    /// original model license. No license acceptance or download is implicit.
    public static func install(modelURL: URL, tokenizerURL: URL) async throws -> LocalReadingModelAssets {
        try await perform { cancellation in
            try install(
                sources: [modelURL, tokenizerURL], assets: [model, tokenizer],
                root: directory(), checkCancellation: cancellation.check)
        }
    }

    /// Revalidates both files. A corrupt or writable installation is an error,
    /// never an invitation to run it or silently fall back to a remote model.
    public static func installed() async throws -> LocalReadingModelAssets? {
        try await perform { cancellation in
            try installed(assets: [model, tokenizer], root: directory(), checkCancellation: cancellation.check)
        }
    }

    private static func directory() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        .appendingPathComponent("QwaveLocalReading", isDirectory: true)
    }

    private static func perform<T: Sendable>(
        _ operation: @escaping @Sendable (ImportCancellation) throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let cancellation = ImportCancellation()
        return try await withTaskCancellationHandler {
            let result = try await LocalReadingWorker.shared.perform {
                try cancellation.check()
                return try operation(cancellation)
            }
            try Task.checkCancellation()
            return result
        } onCancel: {
            cancellation.cancel()
        }
    }

    static func install(
        sources: [URL], assets: [Asset], root: URL, checkCancellation: () throws -> Void
    ) throws -> LocalReadingModelAssets {
        guard sources.count == 2, assets.count == 2 else { throw LocalReadingAssetError.invalidSource }
        try checkCancellation()
        if let existing = try installed(assets: assets, root: root, checkCancellation: checkCancellation) {
            return existing
        }
        let fm = FileManager.default
        if !fm.fileExists(atPath: root.path) {
            try fm.createDirectory(
                at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        try requirePrivateDirectory(root)
        var excludedRoot = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excludedRoot.setResourceValues(values)
        let staging = root.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(
            at: staging, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        // Only this invocation's staging directory is disposable. A complete
        // version is never overwritten, even when cancellation races delivery.
        defer { try? fm.removeItem(at: staging) }
        for (source, asset) in zip(sources, assets) {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let destination = staging.appendingPathComponent(asset.filename)
            try stream(source: source, destination: destination, asset: asset, checkCancellation: checkCancellation)
            try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: destination.path)
            #if os(iOS)
                try fm.setAttributes(
                    [.protectionKey: FileProtectionType.completeUnlessOpen],
                    ofItemAtPath: destination.path)
            #endif
        }
        try checkCancellation()
        let target = versionDirectory(assets: assets, root: root)
        // Same-volume rename publishes the pair together; existing targets fail.
        try fm.moveItem(at: staging, to: target)
        return paths(in: target)
    }

    static func installed(
        assets: [Asset], root: URL, checkCancellation: () throws -> Void
    ) throws -> LocalReadingModelAssets? {
        guard assets.count == 2 else { throw LocalReadingAssetError.invalidStore }
        try checkCancellation()
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        try requirePrivateDirectory(root)
        let target = versionDirectory(assets: assets, root: root)
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        try requirePrivateDirectory(target)
        for asset in assets {
            let url = target.appendingPathComponent(asset.filename)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let mode = attributes[.posixPermissions] as? NSNumber,
                mode.intValue & 0o777 == 0o400,
                (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid()
            else { throw LocalReadingAssetError.invalidStore }
            try stream(source: url, destination: nil, asset: asset, checkCancellation: checkCancellation)
        }
        return paths(in: target)
    }

    private static func paths(in directory: URL) -> LocalReadingModelAssets {
        LocalReadingModelAssets(
            modelURL: directory.appendingPathComponent("model.gguf"),
            tokenizerURL: directory.appendingPathComponent("tokenizer.json"))
    }

    private static func versionDirectory(assets: [Asset], root: URL) -> URL {
        let identifier = SHA256.hash(data: Data(assets.map(\.sha256).joined(separator: ":").utf8))
            .map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(identifier, isDirectory: true)
    }

    private static func requirePrivateDirectory(_ url: URL) throws {
        guard url.isFileURL else { throw LocalReadingAssetError.invalidStore }
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        guard a[.type] as? FileAttributeType == .typeDirectory,
            (a[.posixPermissions] as? NSNumber)?.intValue == 0o700,
            (a[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid()
        else { throw LocalReadingAssetError.invalidStore }
    }

    private static func stream(
        source: URL, destination: URL?, asset: Asset, checkCancellation: () throws -> Void
    ) throws {
        try checkCancellation()
        guard source.isFileURL else { throw LocalReadingAssetError.invalidSource }
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw LocalReadingAssetError.invalidSource
        }
        guard (attributes[.size] as? NSNumber)?.intValue == asset.bytes else {
            throw LocalReadingAssetError.integrityMismatch
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        var output: FileHandle?
        if let destination {
            guard
                FileManager.default.createFile(
                    atPath: destination.path, contents: nil,
                    attributes: [.posixPermissions: 0o600])
            else {
                throw LocalReadingAssetError.invalidStore
            }
            output = try FileHandle(forWritingTo: destination)
        }
        defer { try? output?.close() }
        var hasher = SHA256()
        var remaining = asset.bytes
        while remaining > 0 {
            try checkCancellation()
            let data = try input.read(upToCount: min(1_048_576, remaining)) ?? Data()
            guard !data.isEmpty else { throw LocalReadingAssetError.integrityMismatch }
            hasher.update(data: data)
            try output?.write(contentsOf: data)
            remaining -= data.count
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard (try input.read(upToCount: 1) ?? Data()).isEmpty, digest == asset.sha256 else {
            throw LocalReadingAssetError.integrityMismatch
        }
        try output?.synchronize()
        try checkCancellation()
    }
}

private final class ImportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func check() throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }
}
