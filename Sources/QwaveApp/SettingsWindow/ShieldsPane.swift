import SwiftUI
import Shields
import Persistence

struct ShieldsPane: View {
    @ObservedObject var policy: ShieldsPolicy
    let settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle("Block ads & trackers by default", isOn: $policy.defaultAdsBlocked)
                    .onChange(of: policy.defaultAdsBlocked) { _, newValue in
                        settings.shieldsEnabledByDefault = newValue
                    }
                Toggle("HTTPS-first (upgrade insecure connections)", isOn: $policy.defaultHTTPSFirst)
                    .onChange(of: policy.defaultHTTPSFirst) { _, newValue in
                        settings.httpsFirstEnabled = newValue
                    }
            } header: {
                Text("Defaults")
            } footer: {
                Text("Per-site changes made from the toolbar shield override these defaults.")
                    .foregroundStyle(.secondary)
            }

            Section("Per-site overrides") {
                if policy.overrides.isEmpty {
                    Text("No per-site overrides yet.")
                        .foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach(policy.overrides.keys.sorted(), id: \.self) { host in
                            HStack {
                                Text(host)
                                Spacer()
                                Text(describe(policy.overrides[host] ?? SitePolicy()))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button("Clear") {
                                    policy.setOverride(SitePolicy(), forHost: host)
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                    .frame(minHeight: 120)
                    Button("Clear all overrides") {
                        policy.clearAllOverrides()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(12)
    }

    private func describe(_ sitePolicy: SitePolicy) -> String {
        var parts: [String] = []
        if let ads = sitePolicy.adsBlocked { parts.append(ads ? "ads blocked" : "ads allowed") }
        if let https = sitePolicy.httpsFirst { parts.append(https ? "https on" : "https off") }
        if let js = sitePolicy.jsEnabled { parts.append(js ? "js on" : "js off") }
        return parts.joined(separator: ", ")
    }
}
