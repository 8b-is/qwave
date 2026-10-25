import SwiftUI
import WebKit
import NaturalLanguage
// Translation predates Swift 6 isolation annotations. Each session stays inside its
// translationTask lifetime, with only one in-flight batch and no detached work.
@preconcurrency import Translation
import Persistence
import SovereignCore

public enum ReadingLanguageControls {
    public static let toggle = Notification.Name("QwaveToggleReadingLanguageControls")
    @MainActor public static func show(for webView: WKWebView) {
        NotificationCenter.default.post(name: toggle, object: webView)
    }
}

/// Native browser chrome: pages cannot impersonate the translation controls.
public struct ReadingLanguageBar: View {
    let webView: WKWebView
    @State private var showControls = false
    public init(webView: WKWebView) { self.webView = webView }
    public var body: some View {
        Group {
            if RustLocalReadingSession.isAvailable {
                NativeReadingLanguageBar(webView: webView, showControls: $showControls).id(ObjectIdentifier(webView))
            } else if #available(macOS 15, iOS 18, *) {
                LocalReadingBar(webView: webView, showControls: $showControls).id(ObjectIdentifier(webView))
            } else if showControls {
                LegacyReadingLanguageBar()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ReadingLanguageControls.toggle)) { notification in
            if let target = notification.object as? WKWebView, target === webView { showControls.toggle() }
        }
    }
}

private struct LegacyReadingLanguageBar: View {
    @State private var language = ReadingLanguagePreferences.shared.language
    var body: some View {
        HStack {
            Text("On-device translation requires macOS 15 or iOS 18").font(.caption)
            Picker("Read in", selection: $language) {
                Text("English").tag("en")
                Text("日本語").tag("ja")
                Text("Español").tag("es")
                Text("Français").tag("fr")
                if !["en", "ja", "es", "fr"].contains(language) { Text(language).tag(language) }
            }.frame(maxWidth: 180)
        }.padding(6)
            .onChange(of: language) { ReadingLanguagePreferences.shared.language = $0 }
    }
}

@available(macOS 15, iOS 18, *)
private struct LocalReadingBar: View {
    let webView: WKWebView
    @Binding var showControls: Bool
    @State private var language = ReadingLanguagePreferences.shared.language
    @State private var automatic = ReadingLanguagePreferences.shared.automatic
    @State private var status = "On-device translation"
    @State private var source = ""
    @State private var documentID = ""
    @State private var suppressedDocument = ""
    @State private var busy = false
    @State private var scanning = false
    @State private var needsDownload = false
    @State private var requestedDownloadDocument = ""
    @State private var translated = false
    @State private var generation = 0
    @State private var job: Job?
    @State private var configuration: TranslationSession.Configuration?
    private let world = WKContentWorld.world(name: "QwaveReadingLanguage")
    private let languages = [
        "en", "ja", "es", "fr", "de", "it", "pt", "ko", "zh-Hans", "zh-Hant", "ar", "hi", "uk", "nl",
    ]
    private struct Entry: Sendable { let id: String; let text: String }
    private struct Job {
        let id = UUID()
        let document: String
        let generation: Int
        let target: String
        let entries: [Entry]
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "character.bubble")
            Text(status).font(.caption).lineLimit(2).accessibilityLabel(status)
            Spacer(minLength: 2)
            if needsDownload {
                Button("Download languages") { requestTranslationDownload() }
            }
            if translated {
                Button("Show original") { restore(pause: true) }
            }
            Menu("Language") {
                Picker("Read in", selection: $language) {
                    if !languages.contains(language) {
                        Text(Locale(identifier: "en").localizedString(forIdentifier: language) ?? language).tag(
                            language)
                    }
                    ForEach(languages, id: \.self) { code in
                        Text(Locale(identifier: "en").localizedString(forIdentifier: code) ?? code).tag(code)
                    }
                }
                Toggle("Translate automatically", isOn: $automatic)
                Button("Translate this page") {
                    requestTranslationDownload()
                }
                if let host = webView.url?.host?.lowercased() {
                    Button("Never translate \(host)") {
                        let p = ReadingLanguagePreferences.shared
                        p.excludedHosts = Array(Set(p.excludedHosts + [host])); restore(pause: true)
                    }
                }
                if !source.isEmpty {
                    Button(
                        "Never translate \(Locale(identifier: "en").localizedString(forLanguageCode: source) ?? source)"
                    ) {
                        let p = ReadingLanguagePreferences.shared
                        p.excludedLanguages = Array(
                            Set(p.excludedLanguages + [ReadingLanguagePreferences.base(source)]))
                        restore(pause: true)
                    }
                }
                Button("Reset site and language exceptions") {
                    let p = ReadingLanguagePreferences.shared
                    p.excludedHosts = []; p.excludedLanguages = []; suppressedDocument = ""
                    Task { _ = try? await run("qwaveReading.retry(); return true;") }
                }
            }
        }
        .buttonStyle(.borderless).padding(.horizontal, 10).padding(.vertical, 5)
        .background(.bar)
        .frame(height: (busy || translated || needsDownload || showControls) ? nil : 0)
        .clipped()
        .accessibilityHidden(!(busy || translated || needsDownload || showControls))
        .onChange(of: language) { new in
            ReadingLanguagePreferences.shared.language = new
            restore(pause: false)
        }
        .onChange(of: automatic) { new in
            ReadingLanguagePreferences.shared.automatic = new
            if !new { restore(pause: true) } else if requestedDownloadDocument.isEmpty { restore(pause: false) }
        }
        .onReceive(webView.publisher(for: \.isLoading).removeDuplicates()) { loading in
            guard loading else { return }
            generation += 1
            configuration = nil; job = nil; busy = false; translated = false
            needsDownload = false; requestedDownloadDocument = ""; suppressedDocument = ""; documentID = ""
        }
        .task {
            while !Task.isCancelled {
                await scan()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        .translationTask(configuration) { session in
            guard let current = job else { return }
            defer {
                // A cancelled session must not clear a newer batch.
                if job?.id == current.id { busy = false; job = nil }
            }
            do {
                guard !Task.isCancelled, current.generation == generation else { return }
                let requests = Self.requests(for: current.entries)
                let responses = try await session.translations(from: requests)
                let expected = Dictionary(uniqueKeysWithValues: current.entries.map { ($0.id, $0.text) })
                var seen = Set<String>()
                let rows = responses.compactMap { response -> [String: String]? in
                    guard let id = response.clientIdentifier,
                        expected[id] == response.sourceText, seen.insert(id).inserted
                    else { return nil }
                    return ["id": id, "text": response.targetText]
                }
                // Never apply an incomplete or incorrectly associated batch.
                guard rows.count == current.entries.count else { throw CancellationError() }
                guard !Task.isCancelled, current.generation == generation, suppressedDocument != current.document else {
                    return
                }
                let applied =
                    try await run(
                        "return qwaveReading.apply(doc, rows);", arguments: ["doc": current.document, "rows": rows])
                    as? Bool
                if applied == true, current.generation == generation, suppressedDocument != current.document {
                    translated = true
                    status =
                        "Translated to \(Locale(identifier: "en").localizedString(forIdentifier: current.target) ?? current.target) • On-device"
                }
            } catch {
                guard !Task.isCancelled, current.generation == generation else { return }
                status =
                    "Translation unavailable. Try again from Language; no page text was sent to a translation service."
                suppressedDocument = current.document
            }
        }
    }

    nonisolated private static func requests(for entries: [Entry]) -> [TranslationSession.Request] {
        entries.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id) }
    }

    @MainActor private func run(_ script: String, arguments: [String: Any] = [:]) async throws -> Any {
        try await webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: world) as Any
    }

    @MainActor private func restore(pause: Bool) {
        generation += 1
        configuration = nil; job = nil; busy = false; needsDownload = false
        requestedDownloadDocument = ""
        if pause { suppressedDocument = documentID }
        translated = false; status = "Original • Preferred language: \(language)"
        let restoredGeneration = generation
        Task {
            guard restoredGeneration == generation else { return }
            _ = try? await run("return globalThis.qwaveReading?.restore(pause);", arguments: ["pause": pause])
            if !pause, restoredGeneration == generation { suppressedDocument = "" }
        }
    }

    @MainActor private func requestTranslationDownload() {
        // A language download may present system UI only after this explicit action.
        requestedDownloadDocument = documentID
        needsDownload = false
        suppressedDocument = ""
        ReadingLanguagePreferences.shared.automatic = true
        automatic = true
        Task { _ = try? await run("qwaveReading.retry(); return true;") }
    }

    @MainActor private func scan() async {
        let preferences = ReadingLanguagePreferences.shared
        if language != preferences.language { language = preferences.language; return }
        if automatic != preferences.automatic { automatic = preferences.automatic; return }
        guard !busy, !scanning, !webView.isLoading, ["https", "http"].contains(webView.url?.scheme ?? "") else {
            return
        }
        scanning = true
        let scanGeneration = generation
        defer { scanning = false }
        do {
            guard
                let batch = try await run(
                    PageTranslationScript.install, arguments: ["targetLanguage": language, "automatic": automatic])
                    as? [String: Any],
                let doc = batch["documentID"] as? String,
                let raw = batch["entries"] as? [[String: String]]
            else { return }
            guard !Task.isCancelled, scanGeneration == generation else {
                _ = try? await run(
                    "if (qwaveReading.documentID === doc) qwaveReading.release(ids); return true;",
                    arguments: ["doc": doc, "ids": raw.compactMap { $0["id"] }])
                return
            }
            if doc != documentID {
                needsDownload = false; requestedDownloadDocument = ""
                documentID = doc; translated = batch["translated"] as? Bool ?? false; source = ""
                if batch["paused"] as? Bool == true { suppressedDocument = doc }
                status =
                    translated ? "Translated to \(language) • On-device" : "Original • Preferred language: \(language)"
            }
            guard doc != suppressedDocument else { return }
            let entries = raw.compactMap { row -> Entry? in
                guard let id = row["id"], let text = row["text"] else { return nil }
                return Entry(id: id, text: text)
            }
            guard !entries.isEmpty else { return }
            let detector = NLLanguageRecognizer()
            detector.processString(entries.map(\.text).joined(separator: " "))
            let declaredLanguage = batch["language"] as? String ?? ""
            let fallback = declaredLanguage.isEmpty ? (detector.dominantLanguage?.rawValue ?? "") : declaredLanguage
            // Detect blocks individually so an English page can still contain Japanese UI.
            let classified = entries.map { entry -> (Entry, String) in
                let local = NLLanguageRecognizer()
                local.processString(entry.text)
                return (entry, local.dominantLanguage?.rawValue ?? fallback)
            }
            let candidates = classified.filter {
                !$0.1.isEmpty && preferences.permits(host: webView.url?.host, source: $0.1)
            }
            guard let detected = candidates.first?.1 else {
                if !translated { status = "Original • Preferred language: \(language)" }
                return
            }
            source = detected
            let selected = candidates.filter { $0.1 == detected }.map { $0.0 }
            let deferred = candidates.filter { $0.1 != detected }.map { $0.0.id }
            if !deferred.isEmpty {
                _ = try await run("return qwaveReading.release(ids);", arguments: ["ids": deferred])
            }
            #if targetEnvironment(simulator)
                // Apple's Translation API requires a physical device. Do not
                // leave Simulator waiting on an availability request forever.
                status = "On-device translation needs a physical device"
                suppressedDocument = doc
                return
            #else
                let availability = await LanguageAvailability().status(
                    from: Locale.Language(identifier: detected), to: Locale.Language(identifier: language))
                guard !Task.isCancelled, scanGeneration == generation, doc != suppressedDocument else { return }
                switch availability {
                case .installed: break
                case .supported where requestedDownloadDocument == doc: break
                case .supported:
                    needsDownload = true
                    status = "Download languages to translate this page on-device"
                    suppressedDocument = doc
                    return
                case .unsupported:
                    status = "This language pair is not available on-device"
                    suppressedDocument = doc
                    return
                @unknown default: return
                }
                guard let liveDocument = try await run("return globalThis.qwaveReading?.documentID;") as? String,
                    liveDocument == doc, scanGeneration == generation, doc != suppressedDocument
                else { return }
                needsDownload = false
                busy = true
                job = Job(document: doc, generation: generation, target: language, entries: selected)
                var next = TranslationSession.Configuration(
                    source: Locale.Language(identifier: source), target: Locale.Language(identifier: language))
                if let previous = configuration, previous.source == next.source, previous.target == next.target {
                    next = previous; next.invalidate()
                }
                status = "Translating on-device…"
                configuration = next
            #endif
        } catch { /* A navigation may replace the document during a scan. */  }
    }
}
