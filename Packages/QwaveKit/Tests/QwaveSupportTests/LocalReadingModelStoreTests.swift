import CryptoKit
import Foundation
@testable import SovereignCore
import XCTest

final class LocalReadingModelStoreTests: XCTestCase {
    private let fm = FileManager.default

    private struct Fixture {
        let directory: URL
        let root: URL
        let sources: [URL]
        let bytes: [Data]
        let assets: [LocalReadingModelStore.Asset]
    }

    private func fixture() throws -> Fixture {
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        let bytes = [Data(repeating: 0x71, count: 2_097_159), Data("fixture tokenizer".utf8)]
        let names = ["model.gguf", "tokenizer.json"]
        let sources = names.map { directory.appendingPathComponent($0) }
        for (url, data) in zip(sources, bytes) {
            try data.write(to: url)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        let assets = zip(names, bytes).map { name, data in
            LocalReadingModelStore.Asset(
                filename: name, bytes: data.count,
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
        return Fixture(
            directory: directory, root: directory.appendingPathComponent("managed"),
            sources: sources, bytes: bytes, assets: assets)
    }

    private func install(_ f: Fixture, check: () throws -> Void = {}) throws -> LocalReadingModelAssets {
        try LocalReadingModelStore.install(sources: f.sources, assets: f.assets, root: f.root, checkCancellation: check)
    }

    private func lookup(_ f: Fixture) throws -> LocalReadingModelAssets? {
        try LocalReadingModelStore.installed(assets: f.assets, root: f.root, checkCancellation: {})
    }

    func testVerifiedPairIsPrivateReadOnlyAndIdempotent() throws {
        let f = try fixture()
        defer { try? fm.removeItem(at: f.directory) }
        XCTAssertNil(try lookup(f))
        let result = try install(f)
        let dates = try [result.modelURL, result.tokenizerURL].map {
            try fm.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date
        }
        for (index, url) in [result.modelURL, result.tokenizerURL].enumerated() {
            XCTAssertEqual(try Data(contentsOf: url), f.bytes[index])
            XCTAssertEqual(try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber, 0o400)
            XCTAssertEqual(try Data(contentsOf: f.sources[index]), f.bytes[index])
            XCTAssertEqual(
                try fm.attributesOfItem(atPath: f.sources[index].path)[.posixPermissions] as? NSNumber, 0o600)
        }
        XCTAssertEqual(try fm.attributesOfItem(atPath: f.root.path)[.posixPermissions] as? NSNumber, 0o700)
        let again = try install(f)
        XCTAssertEqual(again.modelURL, result.modelURL)
        XCTAssertEqual(try lookup(f)?.tokenizerURL, result.tokenizerURL)
        XCTAssertEqual(
            try [again.modelURL, again.tokenizerURL].map {
                try fm.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date
            }, dates)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: f.root.path).count, 1)
    }

    func testBadSecondAssetDoesNotPublishFirstOrEditSources() throws {
        let f = try fixture()
        defer { try? fm.removeItem(at: f.directory) }
        let corrupt = Data(repeating: 0x30, count: f.bytes[1].count)
        try corrupt.write(to: f.sources[1])
        XCTAssertThrowsError(try install(f)) { XCTAssertEqual($0 as? LocalReadingAssetError, .integrityMismatch) }
        XCTAssertNil(try lookup(f))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: f.root.path), [])
        XCTAssertEqual(try Data(contentsOf: f.sources[0]), f.bytes[0])
        XCTAssertEqual(try Data(contentsOf: f.sources[1]), corrupt)
    }

    func testWrongSizeRejectedBeforePublishing() throws {
        let f = try fixture()
        defer { try? fm.removeItem(at: f.directory) }
        try Data("short".utf8).write(to: f.sources[0])
        XCTAssertThrowsError(try install(f)) { XCTAssertEqual($0 as? LocalReadingAssetError, .integrityMismatch) }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: f.root.path), [])
    }

    func testCancelledCopyCleansOnlyItsStagingDirectory() throws {
        let f = try fixture()
        defer { try? fm.removeItem(at: f.directory) }
        try fm.createDirectory(at: f.root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let unrelated = f.root.appendingPathComponent("keep.txt")
        try Data("preserve".utf8).write(to: unrelated)
        var checks = 0
        XCTAssertThrowsError(
            try install(f) {
                checks += 1
                if checks == 5 { throw CancellationError() }
            }
        ) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks, 5)
        XCTAssertNil(try lookup(f))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: f.root.path), ["keep.txt"])
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("preserve".utf8))
    }

    func testPreCancelledImportDoesNotCreateStore() throws {
        let f = try fixture()
        defer { try? fm.removeItem(at: f.directory) }
        XCTAssertThrowsError(try install(f) { throw CancellationError() }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(fm.fileExists(atPath: f.root.path))
    }

    func testSymlinkSourceRejectedWithoutFollowingIt() throws {
        let f = try fixture()
        defer { try? fm.removeItem(at: f.directory) }
        let original = f.directory.appendingPathComponent("original.gguf")
        try fm.moveItem(at: f.sources[0], to: original)
        try fm.createSymbolicLink(at: f.sources[0], withDestinationURL: original)
        XCTAssertThrowsError(try install(f)) { XCTAssertEqual($0 as? LocalReadingAssetError, .invalidSource) }
        XCTAssertEqual(try Data(contentsOf: original), f.bytes[0])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: f.root.path), [])
    }

    func testWritableOrCorruptInstallationNeverReusedOrOverwritten() throws {
        let f = try fixture()
        defer { try? fm.removeItem(at: f.directory) }
        let installed = try install(f)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: installed.modelURL.path)
        XCTAssertThrowsError(try lookup(f)) { XCTAssertEqual($0 as? LocalReadingAssetError, .invalidStore) }
        let corrupt = Data(repeating: 0, count: f.bytes[0].count)
        try corrupt.write(to: installed.modelURL)
        try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: installed.modelURL.path)
        XCTAssertThrowsError(try lookup(f)) { XCTAssertEqual($0 as? LocalReadingAssetError, .integrityMismatch) }
        XCTAssertThrowsError(try install(f)) { XCTAssertEqual($0 as? LocalReadingAssetError, .integrityMismatch) }
        XCTAssertEqual(try Data(contentsOf: installed.modelURL), corrupt)
    }

    func testNonPrivateOrSymlinkStoreRejectedWithoutChangingPermissions() throws {
        let f = try fixture()
        defer { try? fm.removeItem(at: f.directory) }
        try fm.createDirectory(at: f.root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        XCTAssertThrowsError(try install(f)) { XCTAssertEqual($0 as? LocalReadingAssetError, .invalidStore) }
        XCTAssertEqual(try fm.attributesOfItem(atPath: f.root.path)[.posixPermissions] as? NSNumber, 0o755)
        try fm.removeItem(at: f.root)
        try fm.createSymbolicLink(at: f.root, withDestinationURL: f.directory)
        XCTAssertThrowsError(try install(f)) { XCTAssertEqual($0 as? LocalReadingAssetError, .invalidStore) }
        XCTAssertEqual(try Data(contentsOf: f.sources[0]), f.bytes[0])
    }

    @MainActor
    func testPublicLookupHonorsAlreadyCancelledTask() async throws {
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LocalReadingModelStore.installed()
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled lookup must not touch model storage")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    @MainActor
    func testLookupDoesNotQueueBehindNativeInference() async throws {
        let release = DispatchSemaphore(value: 0)
        var operation: Task<Bool, Error>?
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            operation = Task.detached {
                do {
                    return try await LocalReadingWorker.shared.perform {
                        ready.resume()
                        return release.wait(timeout: .now() + 5) == .success
                    }
                } catch {
                    // A busy worker fails before entering the closure above.
                    ready.resume(throwing: error)
                    throw error
                }
            }
        }
        defer { release.signal() }
        do {
            _ = try await LocalReadingModelStore.installed()
            XCTFail("Busy lookup must fail without queuing")
        } catch {
            XCTAssertEqual(error as? LocalReadingError, .busy)
        }
        release.signal()
        let released = try await operation?.value
        XCTAssertEqual(released, true)
    }
}
