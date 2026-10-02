import Persistence
import SwiftUI

/// Theme and accessibility controls. Writes straight through to the
/// `SettingsStore`; the ThemeController re-applies the chrome on the defaults
/// change, and new tabs pick up the zoom / reduce-motion values from
/// WebViewFactory.
struct AppearancePane: View {
    let environment: BrowserEnvironment
    @State private var themeMode: ThemeMode = .system
    @State private var defaultZoom: Double = 1.0
    @State private var reduceMotion = false

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Appearance", selection: $themeMode) {
                    ForEach(ThemeMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .onChange(of: themeMode) { _, newValue in
                    environment.settings.themeMode = newValue
                }
                .accessibilityLabel("Appearance")

                Text(
                    "System follows macOS. A forced Light or Dark also sends pages a "
                        + "color-scheme hint, so form controls, scrollbars, and sites that "
                        + "honor it follow your choice. Pages using prefers-color-scheme "
                        + "media queries still see the system value — WebKit exposes no "
                        + "public way to force it, and Qwave does not use private API to "
                        + "fake one."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Accessibility") {
                VStack(alignment: .leading) {
                    Slider(value: $defaultZoom, in: SettingsStore.zoomBounds, step: 0.1) {
                        Text("Default page zoom")
                    }
                    .accessibilityLabel("Default page zoom slider")
                    Text(String(format: "%.0f%%", defaultZoom * 100))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .onChange(of: defaultZoom) { _, newValue in
                    environment.settings.defaultPageZoom = newValue
                }

                Text(
                    "The zoom every new tab starts at. \u{2318}+ / \u{2318}\u{2212} / \u{2318}0 "
                        + "still adjust the current tab afterwards."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Toggle("Reduce motion on web pages", isOn: $reduceMotion)
                    .onChange(of: reduceMotion) { _, newValue in
                        environment.settings.reduceMotionEnabled = newValue
                    }
                    .accessibilityLabel("Reduce motion on web pages")

                Text(
                    "Collapses CSS animations, transitions, and smooth scrolling on every "
                        + "page, independently of the system-wide Reduce Motion setting. "
                        + "Applies to tabs opened after you change this."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .onAppear {
            themeMode = environment.settings.themeMode
            defaultZoom = environment.settings.defaultPageZoom
            reduceMotion = environment.settings.reduceMotionEnabled
        }
    }
}
