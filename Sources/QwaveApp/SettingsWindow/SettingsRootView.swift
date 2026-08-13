import SwiftUI
import Persistence

struct SettingsRootView: View {
    let environment: BrowserEnvironment

    var body: some View {
        TabView {
            GeneralPane(environment: environment)
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
    @State private var searchEngine: SearchEngine = .duckduckgo
    @State private var restoreSession = true
    @State private var hibernationMinutes: Double = 15

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
        }
        .padding(20)
        .onAppear {
            searchEngine = environment.settings.searchEngine
            restoreSession = environment.settings.restoreSessionOnLaunch
            hibernationMinutes = environment.settings.hibernationTimeout / 60
        }
    }
}
