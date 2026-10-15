import Combine
import Foundation
import SovereignCore

struct NativeReadingText {
    let id: String
    let text: String
    let language: LocalReadingLanguage
}

@MainActor
protocol NativeReadingProvider: AnyObject {
    var isReady: Bool { get }
    var isBusy: Bool { get }
    func translate(_ entries: [NativeReadingText], to target: LocalReadingLanguage, request: UUID) async throws
        -> [String]
    func cancel(_ request: UUID)
}

/// One native session for all tabs/windows, with no queue of stale page work.
@MainActor
final class NativeReadingRuntime: ObservableObject, NativeReadingProvider {
    static let shared = NativeReadingRuntime()
    @Published private(set) var isChecking = false
    @Published private(set) var isReady = false
    @Published private(set) var setupMessage = "Set up local translation"
    private var checked = false
    private var assets: LocalReadingModelAssets?
    private var session: RustLocalReadingSession?
    private var activeRequest: UUID?
    private var activeGeneration: RustLocalReadingSession.Generation?
    var isBusy: Bool { isChecking || activeRequest != nil }

    func refresh(force: Bool = false) async {
        guard !isBusy, !checked || force else { return }
        isChecking = true
        checked = true
        defer { isChecking = false }
        do {
            assets = try await LocalReadingModelStore.installed()
            isReady = assets != nil
            setupMessage = isReady ? "Local model ready" : "Choose local model files to translate on this device"
        } catch is CancellationError {
            checked = false
        } catch {
            assets = nil; isReady = false
            setupMessage = "Local model files could not be verified. Originals are unchanged."
        }
    }

    func install(_ urls: [URL]) async {
        guard !isBusy else { return }
        guard urls.count == 2,
            let model = urls.first(where: { $0.pathExtension.lowercased() == "gguf" }),
            let tokenizer = urls.first(where: { $0.pathExtension.lowercased() == "json" })
        else {
            setupMessage = "Choose both the GGUF model and tokenizer.json."
            return
        }
        isChecking = true
        setupMessage = "Checking and copying local model files…"
        defer { isChecking = false; checked = true }
        do {
            assets = try await LocalReadingModelStore.install(modelURL: model, tokenizerURL: tokenizer)
            isReady = true
            setupMessage = "Local model ready"
        } catch is CancellationError {
            setupMessage = "Model setup cancelled"
        } catch {
            setupMessage =
                "These files could not be installed. Use the matching model and tokenizer; originals are unchanged."
        }
    }

    func translate(
        _ entries: [NativeReadingText], to target: LocalReadingLanguage, request: UUID
    ) async throws -> [String] {
        guard !isBusy else { throw LocalReadingError.busy }
        guard let assets, isReady else { throw LocalReadingError.unavailable }
        activeRequest = request
        defer { activeRequest = nil; activeGeneration = nil }
        if session == nil {
            session = try await RustLocalReadingSession.load(
                modelURL: assets.modelURL, tokenizerURL: assets.tokenizerURL)
        }
        try Task.checkCancellation()
        guard let session else { throw LocalReadingError.unavailable }
        let generation = try session.beginGeneration()
        activeGeneration = generation
        var results: [String] = []
        for entry in entries {
            try Task.checkCancellation()
            results.append(
                try await session.translate(entry.text, from: entry.language, to: target, generation: generation))
        }
        try Task.checkCancellation()
        return results
    }

    func cancel(_ request: UUID) {
        guard activeRequest == request, let generation = activeGeneration else { return }
        session?.cancel(generation)
    }
}
