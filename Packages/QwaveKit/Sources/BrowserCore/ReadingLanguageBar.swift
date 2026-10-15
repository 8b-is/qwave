import SwiftUI
import WebKit
import NaturalLanguage
// Translation predates Swift 6 isolation annotations. Each session stays inside its
// translationTask lifetime, with only one in-flight batch and no detached work.
@preconcurrency import Translation
import Persistence

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
            if #available(macOS 15, iOS 18, *) {
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
    @State private var translated = false
    @State private var generation = 0
    @State private var job: Job?
    @State private var configuration: TranslationSession.Configuration?
    private let world = WKContentWorld.world(name: "QwaveReadingLanguage")
    private let languages = [
        "en", "ja", "es", "fr", "de", "it", "pt", "ko", "zh-Hans", "zh-Hant", "ar", "hi", "uk", "nl",
    ]
    private struct Entry { let id: String; let text: String }
    private struct Job { let document: String; let generation: Int; let entries: [Entry] }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "character.bubble")
            Text(status).font(.caption).lineLimit(2).accessibilityLabel(status)
            Spacer(minLength: 2)
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
                    suppressedDocument = ""; automatic = true
                    Task { _ = try? await run("qwaveReading.retry(); return true;") }
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
        .frame(height: (busy || translated || showControls) ? nil : 0)
        .clipped()
        .accessibilityHidden(!(busy || translated || showControls))
        .onChange(of: language) { new in
            ReadingLanguagePreferences.shared.language = new
            restore(pause: false)
        }
        .onChange(of: automatic) { new in
            ReadingLanguagePreferences.shared.automatic = new
            if !new { restore(pause: true) } else { restore(pause: false) }
        }
        .task {
            while !Task.isCancelled {
                await scan()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        .translationTask(configuration) { session in
            guard let current = job else { return }
            defer { busy = false }
            do {
                var rows: [[String: String]] = []
                for entry in current.entries {
                    guard !Task.isCancelled, current.generation == generation else { return }
                    let response = try await session.translate(entry.text)
                    rows.append(["id": entry.id, "text": response.targetText])
                }
                guard !Task.isCancelled, current.generation == generation, suppressedDocument != current.document else {
                    return
                }
                let applied =
                    try await run(
                        "return qwaveReading.apply(doc, rows);", arguments: ["doc": current.document, "rows": rows])
                    as? Bool
                if applied == true {
                    translated = true
                    status =
                        "Translated to \(Locale(identifier: "en").localizedString(forIdentifier: language) ?? language) • On-device"
                }
            } catch {
                guard !Task.isCancelled, current.generation == generation else { return }
                status =
                    "Translation unavailable. Try again from Language; no page text was sent to a translation service."
                suppressedDocument = current.document
            }
        }
    }

    @MainActor private func run(_ script: String, arguments: [String: Any] = [:]) async throws -> Any {
        try await webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: world) as Any
    }

    @MainActor private func restore(pause: Bool) {
        generation += 1
        if pause { suppressedDocument = documentID }
        translated = false; status = "Original • Preferred language: \(language)"
        Task {
            _ = try? await run("return globalThis.qwaveReading?.restore(pause);", arguments: ["pause": pause])
            if !pause { suppressedDocument = "" }
        }
    }

    @MainActor private func scan() async {
        let preferences = ReadingLanguagePreferences.shared
        if language != preferences.language { language = preferences.language; return }
        if automatic != preferences.automatic { automatic = preferences.automatic; return }
        guard !busy, !webView.isLoading, ["https", "http"].contains(webView.url?.scheme ?? "") else { return }
        do {
            guard
                let batch = try await run(
                    PageTranslationScript.install, arguments: ["targetLanguage": language, "automatic": automatic])
                    as? [String: Any],
                let doc = batch["documentID"] as? String,
                let raw = batch["entries"] as? [[String: String]]
            else { return }
            if doc != documentID {
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
            let fallback = detector.dominantLanguage?.rawValue ?? (batch["language"] as? String ?? "")
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
            busy = true
            job = Job(document: doc, generation: generation, entries: selected)
            var next = TranslationSession.Configuration(
                source: Locale.Language(identifier: source), target: Locale.Language(identifier: language))
            if let previous = configuration, previous.source == next.source, previous.target == next.target {
                next = previous; next.invalidate()
            }
            status = "Translating on-device…"
            configuration = next
        } catch { /* A navigation may replace the document during a scan. */  }
    }
}
