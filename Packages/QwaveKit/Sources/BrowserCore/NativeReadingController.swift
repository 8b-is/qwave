import Combine
import Foundation
import NaturalLanguage
import Persistence
import SovereignCore
import WebKit

@MainActor
final class NativeReadingController: ObservableObject {
    @Published private(set) var status = "Local translation · originals preserved"
    @Published private(set) var isBusy = false
    @Published private(set) var isTranslating = false
    @Published private(set) var isTranslated = false
    @Published private(set) var hasIssue = false
    @Published private(set) var source = ""
    private weak var webView: WKWebView?
    private let provider: any NativeReadingProvider
    private let preferences: ReadingLanguagePreferences
    private let world = WKContentWorld.world(name: "QwaveNativeReading")
    private var task: Task<Void, Never>?
    private var request = UUID()
    private var document = ""
    private var suppressed = ""
    private var paused = false

    init(webView: WKWebView, provider: any NativeReadingProvider, preferences: ReadingLanguagePreferences = .shared) {
        self.webView = webView
        self.provider = provider
        self.preferences = preferences
    }

    func navigation() {
        invalidate()
        document = ""; suppressed = ""; paused = false; isTranslated = false; hasIssue = false; source = ""
        status = "Local translation · originals preserved"
    }

    func suspend() {
        // Switching tabs cancels inference but must not undo Show original.
        restore(pause: paused)
    }

    /// The reset is ordered in the same content world as delivery. Invalidate
    /// both Swift work and the DOM token; already-applied text is restored too.
    func restore(pause: Bool) {
        invalidate()
        let current = request
        let oldDocument = document
        paused = pause
        suppressed = pause ? oldDocument : ""
        isTranslated = false; hasIssue = false; isBusy = true
        status = pause ? "Original · translation stopped" : "Local translation · originals preserved"
        task = Task { [weak self] in
            guard let self, self.request == current, !Task.isCancelled else { return }
            defer { if self.request == current { self.isBusy = false; self.task = nil } }
            _ = try? await self.run(
                """
                if (globalThis.qwaveReading && (!doc || qwaveReading.documentID === doc)) {
                  qwaveReading.nativeRequest = token;
                  qwaveReading.restore(pause);
                  if (!pause) qwaveReading.retry();
                }
                return true;
                """, arguments: ["doc": oldDocument, "token": current.uuidString, "pause": pause])
        }
    }

    private func invalidate() {
        task?.cancel()
        provider.cancel(request)
        task = nil; request = UUID(); isBusy = false; isTranslating = false
    }

    func scan() {
        guard !paused, !isBusy, provider.isReady, !provider.isBusy, let webView, !webView.isLoading,
            ["http", "https"].contains(webView.url?.scheme ?? ""), preferences.automatic,
            document.isEmpty || document != suppressed
        else { return }
        guard let target = LocalReadingLanguage(rawValue: ReadingLanguagePreferences.base(preferences.language)) else {
            status = "Local model supports English and Japanese. Your saved language is unchanged."
            hasIssue = true
            return
        }
        isBusy = true
        let current = UUID()
        request = current
        task = Task { [weak self] in
            guard let self else { return }
            await self.translateNext(target: target, current: current)
        }
    }

    private func translateNext(target: LocalReadingLanguage, current: UUID) async {
        defer { if request == current { isBusy = false; isTranslating = false; task = nil } }
        var selected: [NativeReadingText] = []
        var doc = ""
        do {
            guard
                let batch = try await run(
                    PageTranslationScript.install,
                    arguments: ["targetLanguage": target.rawValue, "automatic": true]) as? [String: Any],
                let batchDocument = batch["documentID"] as? String,
                let entries = batch["entries"] as? [[String: String]], request == current, !Task.isCancelled
            else { return }
            doc = batchDocument
            if document != doc {
                document = doc
                isTranslated = batch["translated"] as? Bool ?? false
                if batch["paused"] as? Bool == true { suppressed = doc }
            }
            guard doc != suppressed else { return }
            let declared = batch["language"] as? String ?? ""
            source = declared.isEmpty ? "" : ReadingLanguagePreferences.base(declared)
            let candidates = entries.compactMap { entry -> NativeReadingText? in
                guard let id = entry["id"], let text = entry["text"], text.utf8.count <= 4096 else { return nil }
                let detector = NLLanguageRecognizer()
                detector.processString(text)
                let language = detector.dominantLanguage?.rawValue ?? declared
                guard preferences.permits(host: webView?.url?.host, source: language),
                    let source = LocalReadingLanguage(rawValue: ReadingLanguagePreferences.base(language)),
                    source != target
                else { return nil }
                return NativeReadingText(id: id, text: text, language: source)
            }
            // Limit each pass; there is no inference queue or unbounded page job.
            selected = Array(candidates.prefix(4))
            if source.isEmpty { source = selected.first?.language.rawValue ?? "" }
            let deferred = candidates.dropFirst(4).map(\.id)
            try Task.checkCancellation()
            guard request == current else { return }
            let armed =
                try await run(
                    """
                    if (qwaveReading.documentID !== doc) return false;
                    qwaveReading.nativeRequest = token; qwaveReading.release(ids); return true;
                    """, arguments: ["doc": doc, "token": current.uuidString, "ids": deferred]) as? Bool
            guard armed == true, request == current, !Task.isCancelled, !selected.isEmpty else { return }
            status = "Translating locally…"; hasIssue = false; isTranslating = true
            let results = try await provider.translate(selected, to: target, request: current)
            guard request == current, !Task.isCancelled, suppressed != doc else { return }
            guard results.count == selected.count,
                results.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            else {
                throw LocalReadingError.failed
            }
            let rows = zip(selected, results).map { ["id": $0.0.id, "text": $0.1] }
            let applied =
                try await run(
                    """
                    if (qwaveReading.nativeRequest !== token) return false;
                    return qwaveReading.apply(doc, rows);
                    """, arguments: ["doc": doc, "token": current.uuidString, "rows": rows]) as? Bool
            if applied == true, request == current, !Task.isCancelled {
                isTranslated = true
                status = "Translated to \(target == .english ? "English" : "日本語") · Local model"
            }
        } catch {
            guard request == current, !Task.isCancelled else { return }
            if error as? LocalReadingError == .busy {
                _ = try? await run(
                    "if (qwaveReading.documentID === doc && qwaveReading.nativeRequest === token) qwaveReading.release(ids); return true;",
                    arguments: ["doc": doc, "token": current.uuidString, "ids": selected.map(\.id)])
                return
            }
            suppressed = doc
            status = "Local translation could not finish. Untranslated text remains original; retry from Language."
            hasIssue = true
        }
    }

    private func run(_ script: String, arguments: [String: Any] = [:]) async throws -> Any? {
        try Task.checkCancellation()
        guard let webView else { throw CancellationError() }
        return try await webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: world)
    }
}
