import Persistence
import Sparkle
import SwiftUI

struct SettingsRootView: View {
    let environment: BrowserEnvironment
    let updater: SPUUpdater?

    var body: some View {
        TabView {
            GeneralPane(environment: environment, updater: updater)
                .tabItem { Label("General", systemImage: "gearshape") }
            ContainersPane(containers: environment.containers, history: environment.history)
                .tabItem { Label("Containers", systemImage: "square.stack.3d.up") }
            ShieldsPane(policy: environment.shieldsPolicy, settings: environment.settings)
                .tabItem { Label("Shields", systemImage: "shield.lefthalf.filled") }
            FeatureFlagsPane(service: environment.featureFlags)
                .tabItem { Label("Web Features", systemImage: "flask") }
            VPNPane(vpn: environment.vpn)
                .tabItem { Label("VPN", systemImage: "lock.shield") }
            MemoryWavePane(environment: environment)
                .tabItem { Label("Memory Wave", systemImage: "waveform") }
        }
        .frame(minWidth: 700, minHeight: 480)
        .padding(8)
    }
}

private struct GeneralPane: View {
    let environment: BrowserEnvironment
    let updater: SPUUpdater?
    @State private var searchEngine: SearchEngine = .duckduckgo
    @State private var restoreSession = true
    @State private var hibernationMinutes: Double = 15
    @State private var autoCheckUpdates = false

    var body: some View {
        Form {
            Picker("Default search engine", selection: $searchEngine) {
                ForEach(SearchEngine.allCases) { engine in
                    Text(engine.displayName).tag(engine)
                }
            }
            .onChange(of: searchEngine) { _, newValue in
                environment.settings.searchEngine = newValue
            }

            Toggle("Restore previous session at launch", isOn: $restoreSession)
                .onChange(of: restoreSession) { _, newValue in
                    environment.settings.restoreSessionOnLaunch = newValue
                }

            VStack(alignment: .leading) {
                Slider(value: $hibernationMinutes, in: 1...60, step: 1) {
                    Text("Hibernate background tabs after")
                }
                Text("\(Int(hibernationMinutes)) minutes of inactivity")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: hibernationMinutes) { _, newValue in
                environment.settings.hibernationTimeout = newValue * 60
            }

            if let updater {
                Divider()
                Toggle("Check for updates automatically", isOn: $autoCheckUpdates)
                    .onChange(of: autoCheckUpdates) { _, newValue in
                        updater.automaticallyChecksForUpdates = newValue
                    }
                Text(
                    "When on, Qwave periodically asks GitHub whether a newer signed "
                        + "release exists. When off, no update check runs unless you choose "
                        + "\u{201C}Check for Updates\u{2026}\u{201D} from the menu. Qwave never checks "
                        + "before you\u{2019}ve answered this the first time."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Divider()
            Link(
                "What does Qwave send?",
                destination: URL(string: "https://github.com/8b-is/qwave/blob/main/docs/NETWORK.md")!
            )
            .font(.caption)
        }
        .padding(20)
        .onAppear {
            searchEngine = environment.settings.searchEngine
            restoreSession = environment.settings.restoreSessionOnLaunch
            hibernationMinutes = environment.settings.hibernationTimeout / 60
            autoCheckUpdates = updater?.automaticallyChecksForUpdates ?? false
        }
    }
}
