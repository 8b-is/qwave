import Foundation
import RustCoreABI

public enum LocalReadingLanguage: String, Codable, Sendable {
    case english = "en"
    case japanese = "ja"
}

public enum LocalReadingError: Error, Equatable, Sendable {
    case unavailable
    case invalidInput
    case invalidSession
    case busy
    case cancelled
    case model
    case outputTooLarge
    case failed
}

/// One native worker shared by all local sessions. A busy caller fails promptly;
/// the UI may retain only its latest document request, without queuing old pages.
private final class LocalReadingWorker: @unchecked Sendable {
    static let shared = LocalReadingWorker()
    private let queue = DispatchQueue(label: "is.8b.qwave.local-reading", qos: .utility)
    private let lock = NSLock()
    private var busy = false

    private func reserve() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !busy else { return false }
        busy = true
        return true
    }

    private func release() {
        lock.lock()
        busy = false
        lock.unlock()
    }

    func perform<T: Sendable>(
        _ action: @escaping @Sendable () throws -> T
    ) async throws -> T {
        guard reserve() else { throw LocalReadingError.busy }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let result = Result { try action() }
                self.release()
                continuation.resume(with: result)
            }
        }
    }
}

/// Shared Swift face for the optional local model in qwave-core. No downloads,
/// network fallback, or playback. Default builds report unavailable honestly.
/// The native ID registry serializes generation/cancellation/lifetime; the Swift
/// worker bounds inference. Immutable handles therefore cross threads safely.
public final class RustLocalReadingSession: @unchecked Sendable {
    public struct Generation: Sendable, Equatable {
        fileprivate let id: UInt64
        fileprivate let session: UInt64
    }

    private let handle: UInt64
    private static let maxJSON = 65_536

    public static var isAvailable: Bool { qw_reading_abi_version() == 1 }

    private init(handle: UInt64) {
        self.handle = handle
    }

    deinit {
        _ = qw_reading_close(handle)
    }

    /// Assets must already exist in a private, immutable, host-owned location.
    /// The native implementation checks pinned hashes. Loading stays off the UI.
    public static func load(modelURL: URL, tokenizerURL: URL) async throws -> RustLocalReadingSession {
        guard isAvailable else { throw LocalReadingError.unavailable }
        guard modelURL.isFileURL, tokenizerURL.isFileURL else { throw LocalReadingError.invalidInput }
        try Task.checkCancellation()
        let config = try JSONEncoder().encode([
            "model_path": modelURL.path,
            "tokenizer_path": tokenizerURL.path,
        ])
        guard config.count <= maxJSON else { throw LocalReadingError.invalidInput }
        let session = try await LocalReadingWorker.shared.perform {
            var handle: UInt64 = 0
            let status = config.withUnsafeBytes { buffer in
                qw_reading_open(buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, &handle)
            }
            try check(status)
            guard handle != 0 else { throw LocalReadingError.failed }
            return RustLocalReadingSession(handle: handle)
        }
        // A cancelled load releases the returned session; it must never enable
        // a mode after the user has left it. Native hashing itself is bounded.
        try Task.checkCancellation()
        return session
    }

    /// Call on navigation or explicit new reading work. Old generations can
    /// never be reused. The UI also owns and must recheck its document identity.
    public func beginGeneration() throws -> Generation {
        var generation: UInt64 = 0
        try Self.check(qw_reading_begin(handle, &generation))
        guard generation != 0 else { throw LocalReadingError.failed }
        return Generation(id: generation, session: handle)
    }

    /// Does not wait behind inference. A cancelled old task cannot stop a newer
    /// generation. nil explicitly cancels all current work (e.g. mode exit).
    public func cancel(_ generation: Generation? = nil) {
        if let generation, generation.session != handle { return }
        _ = qw_reading_cancel(handle, generation?.id ?? 0)
    }

    public func translate(
        _ text: String, from source: LocalReadingLanguage, to target: LocalReadingLanguage,
        generation: Generation
    ) async throws -> String {
        struct Input: Encodable {
            let source_language: LocalReadingLanguage
            let target_language: LocalReadingLanguage
            let text: String
        }
        struct Request: Encodable {
            let task = "translate"
            let request: Input
        }
        struct Response: Decodable { let text: String }
        guard source != target, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            text.utf8.count <= 4096
        else { throw LocalReadingError.invalidInput }
        let data = try JSONEncoder().encode(
            Request(request: Input(source_language: source, target_language: target, text: text)))
        let result = try await run(data, generation: generation)
        return try JSONDecoder().decode(Response.self, from: result).text
    }

    public func summarize(
        sentences: [String], generation: Generation
    ) async throws -> [String] {
        struct Request: Encodable {
            let task = "summarize"
            let sentences: [String]
        }
        struct Response: Decodable { let sentences: [String] }
        guard (1...32).contains(sentences.count),
            sentences.allSatisfy({
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 1024
            })
        else { throw LocalReadingError.invalidInput }
        let data = try JSONEncoder().encode(Request(sentences: sentences))
        let result = try await run(data, generation: generation)
        return try JSONDecoder().decode(Response.self, from: result).sentences
    }

    private func run(_ input: Data, generation: Generation) async throws -> Data {
        guard generation.session == handle else { throw LocalReadingError.invalidSession }
        guard input.count <= Self.maxJSON else { throw LocalReadingError.invalidInput }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = try await LocalReadingWorker.shared.perform {
                var output = [UInt8](repeating: 0, count: Self.maxJSON)
                var written = 0
                let status = input.withUnsafeBytes { bytes in
                    qw_reading_run(
                        self.handle, generation.id,
                        bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count,
                        &output, output.count, &written)
                }
                try Self.check(status)
                guard (1...output.count).contains(written) else { throw LocalReadingError.failed }
                return Data(output.prefix(written))
            }
            try Task.checkCancellation()
            return result
        } onCancel: {
            self.cancel(generation)
        }
    }

    private static func check(_ status: UInt32) throws {
        switch status {
        case 0: return
        case 1: throw LocalReadingError.unavailable
        case 2: throw LocalReadingError.invalidInput
        case 3: throw LocalReadingError.invalidSession
        case 4: throw LocalReadingError.busy
        case 5: throw LocalReadingError.cancelled
        case 6: throw LocalReadingError.model
        case 7: throw LocalReadingError.outputTooLarge
        default: throw LocalReadingError.failed
        }
    }
}
