import SwiftUI
import MemoryWave

struct MemoryWavePane: View {
    let environment: BrowserEnvironment
    @State private var provider: MemoryProviderKind = .none
    @State private var baseURL = MemoryWavePreferences.defaultRemoteBaseURL.absoluteString
    @State private var model = MemoryWavePreferences.defaultRemoteModel
    @State private var apiKey = ""
    @State private var status = ""

    var body: some View {
        Form {
            Section("Substrate") {
                Text("Stored memories are Cognitive waves: encrypted on this Mac, scoped to the container, never written from ephemeral or private tabs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Remote providers never receive stored memory. They see only the current prompt and, if you include it, the current page.")
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
                    TextField("Base URL", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
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
                        .onChange(of: model) { _, newValue in
                            environment.memoryPreferences.remoteModel = newValue
                        }
                    SecureField("API key (Keychain)", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
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
                Button("Forget all memories on this Mac", role: .destructive) {
                    try? environment.memoryWave.store?.deleteAll()
                    status = "Local wave store emptied."
                }
            }
        }
        .padding(20)
        .onAppear {
            provider = environment.memoryPreferences.providerKind
            baseURL = environment.memoryPreferences.remoteBaseURL.absoluteString
            model = environment.memoryPreferences.remoteModel
            apiKey = (try? environment.memoryPreferences.apiKey()) ?? ""
        }
    }
}
