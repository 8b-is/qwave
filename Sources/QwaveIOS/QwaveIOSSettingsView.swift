// QwaveIOSSettingsView.swift — the iPhone lane's settings sheet.
//
// Same settings, same defaults as the desktop: search engine (Ecosia or
// DuckDuckGo), opt-in network suggestions, theme, default page zoom, and
// reduce motion. All of them are read by the shared QwaveKit code paths —
// WebViewFactory applies zoom/reduce-motion/theme, the suggestion engine
// respects the engine and the opt-in.

import SwiftUI
import Persistence

struct QwaveIOSSettingsView: View {
    @ObservedObject var model: BrowserViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var searchEngine: SearchEngine = .ecosia
    @State private var networkSuggestions = false
    @State private var themeMode: ThemeMode = .system
    @State private var defaultZoom: Double = 1.0
    @State private var reduceMotion = false

    @State private var confirmForget = false

    var body: some View {
        NavigationView {
            Form {
                Section("Search") {
                    Picker("Search engine", selection: $searchEngine) {
                        ForEach(SearchEngine.allCases) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }
                    .onChange(of: searchEngine) { newValue in
                        model.settings.searchEngine = newValue
                    }

                    Toggle("Search suggestions as you type", isOn: $networkSuggestions)
                        .onChange(of: networkSuggestions) { newValue in
                            model.settings.networkSuggestionsEnabled = newValue
                        }

                    Text(
                        "When off (the default), suggestions come only from your open tabs "
                            + "\u{2014} nothing is sent anywhere. When on, each keystroke goes "
                            + "to your search engine's autocomplete endpoint, cookieless and "
                            + "gated by the sovereign core's egress allowlist."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section("Appearance") {
                    Picker("Theme", selection: $themeMode) {
                        ForEach(ThemeMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .onChange(of: themeMode) { newValue in
                        model.settings.themeMode = newValue
                    }
                }

                Section("Memory Wave") {
                    Text("Use Remember this page to save a suggestion on your Wave home. Saved titles and links stay on this device; browsing is not automatically recorded.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Clear saved Memory Waves", role: .destructive) { confirmForget = true }
                }

                Section("Accessibility") {
                    VStack(alignment: .leading) {
                        Slider(value: $defaultZoom, in: SettingsStore.zoomBounds, step: 0.1) {
                            Text("Default page zoom")
                        }
                        Text(String(format: "%.0f%%", defaultZoom * 100))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .onChange(of: defaultZoom) { newValue in
                        model.settings.defaultPageZoom = newValue
                    }

                    Toggle("Reduce motion on web pages", isOn: $reduceMotion)
                        .onChange(of: reduceMotion) { newValue in
                            model.settings.reduceMotionEnabled = newValue
                        }
                }
            }
            .navigationTitle("Qwave Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                searchEngine = model.settings.searchEngine
                networkSuggestions = model.settings.networkSuggestionsEnabled
                themeMode = model.settings.themeMode
                defaultZoom = model.settings.defaultPageZoom
                reduceMotion = model.settings.reduceMotionEnabled
            }
        }
        .navigationViewStyle(.stack)
        .confirmationDialog("Clear all saved Memory Waves on this device?", isPresented: $confirmForget,
                            titleVisibility: .visible) {
            Button("Clear Memory Waves", role: .destructive, action: model.forgetMemories)
        }
    }
}
