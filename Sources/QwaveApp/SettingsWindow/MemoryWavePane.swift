import SwiftUI
import AppKit
import MemoryWave

struct MemoryWavePane: View {
    let environment: BrowserEnvironment
    @State private var provider: MemoryProviderKind = .none
    @State private var baseURL = MemoryWavePreferences.defaultRemoteBaseURL.absoluteString
    @State private var model = MemoryWavePreferences.defaultRemoteModel
    @State private var apiKey = ""
    @State private var status = ""
    @State private var rememberEverything = false

    var body: some View {
        Form {
            Section("Substrate") {
                Text(
                    "Stored memories are Cognitive waves: encrypted on this Mac, scoped to the container, never written from ephemeral or private tabs."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(
                    "Remote providers never receive stored memory. They see only the current prompt and, if you include it, the current page."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Toggle("Remember everything (local)", isOn: $rememberEverything)
                    .onChange(of: rememberEverything) { _, newValue in
                        environment.memoryPreferences.rememberEverything = newValue
                    }
                Text(
                    "When on, every non-private page is captured as a Cognitive wave on this Mac. Private and ephemeral tabs are still never written. Timeline summaries stay local; remote providers only see titles and times, never page bodies."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Inference provider") {
                Picker("Provider", selection: $provider) {
                    Text("Off (remember only)").tag(MemoryProviderKind.none)
                    Text("On-device (Apple Intelligence)").tag(MemoryProviderKind.onDevice)
                    Text("OpenAI-compatible (xAI, Ollama, …)").tag(MemoryProviderKind.openaiCompatible)
                }
                .onChange(of: provider) { _, newValue in
                    environment.memoryPreferences.providerKind = newValue
                }
            }

            if provider == .openaiCompatible {
                Section("Remote endpoint") {
                    Text(
                        "Pages you summarise or ask about with this provider are sent to this endpoint. Nothing else is: stored memories stay on this Mac, and timeline summaries send only titles and times."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    TextField("Base URL", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Remote Base URL")
                        .onChange(of: baseURL) { _, newValue in
                            if let url = URL(string: newValue), url.scheme?.lowercased() == "https" {
                                environment.memoryPreferences.remoteBaseURL = url
                                status = ""
                            } else {
                                status = "HTTPS is required."
                            }
                        }
                    TextField("Model", text: $model)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Remote Model")
                        .onChange(of: model) { _, newValue in
                            environment.memoryPreferences.remoteModel = newValue
                        }
                    SecureField("API key (Keychain)", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("API Key")
                        .onChange(of: apiKey) { _, newValue in
                            try? environment.memoryPreferences.setAPIKey(newValue)
                        }
                    Text("Default endpoint is api.x.ai. Any HTTPS chat/completions server works.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !status.isEmpty {
                Text(status).foregroundStyle(.orange)
            }

            Section("Housekeeping") {
                Button("Open nibble folder") {
                    if let directory = environment.memoryWave.vault?.directory {
                        NSWorkspace.shared.open(directory)
                    }
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Open nibble folder in Finder")
                Button("Forget all memories on this Mac", role: .destructive) {
                    Task { @MainActor in
                        try? await environment.memoryWave.forgetAll()
                        status = "Local wave store emptied."
                    }
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Forget all memories on this Mac")
            }
        }
        .padding(16)
        .onAppear {
            provider = environment.memoryPreferences.providerKind
            baseURL = environment.memoryPreferences.remoteBaseURL.absoluteString
            model = environment.memoryPreferences.remoteModel
            apiKey = (try? environment.memoryPreferences.apiKey()) ?? ""
            rememberEverything = environment.memoryPreferences.rememberEverything
        }
    }
}
