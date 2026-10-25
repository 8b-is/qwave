import Persistence
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Shared macOS/iOS chrome. Only builds containing the native ABI use this view.
@MainActor
struct NativeReadingLanguageBar: View {
    let webView: WKWebView
    @Binding var showControls: Bool
    @ObservedObject private var runtime = NativeReadingRuntime.shared
    @StateObject private var controller: NativeReadingController
    @State private var language = ReadingLanguagePreferences.shared.language
    @State private var automatic = ReadingLanguagePreferences.shared.automatic
    @State private var showSetup = false
    @State private var chooseFiles = false

    init(webView: WKWebView, showControls: Binding<Bool>) {
        self.webView = webView
        _showControls = showControls
        _controller = StateObject(
            wrappedValue: NativeReadingController(webView: webView, provider: NativeReadingRuntime.shared))
    }

    private var visible: Bool {
        showControls || controller.isTranslating || controller.isTranslated || controller.hasIssue || runtime.isChecking
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "character.bubble")
            Text(runtime.isReady ? controller.status : runtime.setupMessage).font(.caption).lineLimit(2)
            Spacer(minLength: 2)
            if !runtime.isReady {
                Button("Set up") { showSetup = true }.disabled(runtime.isChecking)
            }
            if controller.isBusy {
                Button("Stop") { controller.restore(pause: true) }
            } else if controller.isTranslated {
                Button("Show original") { controller.restore(pause: true) }
            }
            Menu("Language") {
                Picker("Read in", selection: $language) {
                    Text("English").tag("en")
                    Text("日本語").tag("ja")
                    if !["en", "ja"].contains(language) {
                        Text(Locale(identifier: "en").localizedString(forIdentifier: language) ?? language).tag(
                            language)
                    }
                }
                Toggle("Translate automatically", isOn: $automatic)
                Button("Translate this page") {
                    if runtime.isReady {
                        automatic = true
                        controller.restore(pause: false)
                    } else {
                        showSetup = true
                    }
                }
                if let host = webView.url?.host?.lowercased() {
                    Button("Never translate \(host)") {
                        let preferences = ReadingLanguagePreferences.shared
                        preferences.excludedHosts = Array(Set(preferences.excludedHosts + [host]))
                        controller.restore(pause: true)
                    }
                }
                if !controller.source.isEmpty {
                    Button(
                        "Never translate \(Locale(identifier: "en").localizedString(forLanguageCode: controller.source) ?? controller.source)"
                    ) {
                        let preferences = ReadingLanguagePreferences.shared
                        preferences.excludedLanguages = Array(Set(preferences.excludedLanguages + [controller.source]))
                        controller.restore(pause: true)
                    }
                }
                Button("Reset site and language exceptions") {
                    let preferences = ReadingLanguagePreferences.shared
                    preferences.excludedHosts = []; preferences.excludedLanguages = []
                    controller.restore(pause: false)
                }
                Button("Local model setup") { showSetup = true }
            }
        }
        .buttonStyle(.borderless).padding(.horizontal, 10).padding(.vertical, 5)
        .background(.bar).frame(height: visible ? nil : 0).clipped().accessibilityHidden(!visible)
        .sheet(isPresented: $showSetup) { setup }
        .onChange(of: language) { new in
            ReadingLanguagePreferences.shared.language = new
            controller.restore(pause: false)
        }
        .onChange(of: automatic) { new in
            ReadingLanguagePreferences.shared.automatic = new
            controller.restore(pause: !new)
        }
        .onReceive(webView.publisher(for: \.isLoading).removeDuplicates()) { loading in
            if loading { controller.navigation() }
        }
        .task {
            await runtime.refresh()
            while !Task.isCancelled {
                let preferences = ReadingLanguagePreferences.shared
                if language != preferences.language { language = preferences.language }
                if automatic != preferences.automatic { automatic = preferences.automatic }
                controller.scan()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        .onDisappear { controller.suspend() }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Local translation").font(.headline)
            Text(
                "Choose the LFM2.5-1.2B-Instruct Q4_K_M GGUF and its matching tokenizer.json already on your device. Qwave verifies and copies both files (about 736 MB)."
            )
            Text(
                "English and Japanese are supported. Page text stays on this device. Model files are distributed separately under the LFM Open License 1.0."
            )
            Text(runtime.setupMessage).font(.caption).accessibilityIdentifier("local-model-status")
            HStack {
                Button("Choose model files…") { chooseFiles = true }.disabled(runtime.isBusy)
                Button("Check again") { Task { await runtime.refresh(force: true) } }.disabled(runtime.isBusy)
                Spacer()
                Button("Done") { showSetup = false }
            }
        }.padding(20).frame(idealWidth: 460)
            .fileImporter(isPresented: $chooseFiles, allowedContentTypes: [.data], allowsMultipleSelection: true) {
                result in
                if case .success(let urls) = result { Task { await runtime.install(urls) } }
            }
    }
}
