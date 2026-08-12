import SwiftUI
import Shields

/// Brave-style per-site shields popover, anchored to the toolbar shield.
struct ShieldsPopoverView: View {
    let host: String
    @ObservedObject var policy: ShieldsPolicy
    var onChanged: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Shields for \(host)")
                .font(.headline)

            Toggle("Block ads & trackers", isOn: binding(\.adsBlocked, default: policy.defaultAdsBlocked))
            Toggle("Upgrade to HTTPS", isOn: binding(\.httpsFirst, default: policy.defaultHTTPSFirst))
            Toggle("Allow JavaScript", isOn: binding(\.jsEnabled, default: true))

            Divider()

            Button("Reset to defaults") {
                policy.setOverride(SitePolicy(), forHost: host)
                onChanged()
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 260)
    }

    private func binding(_ keyPath: WritableKeyPath<SitePolicy, Bool?>, default defaultValue: Bool) -> Binding<Bool> {
        Binding(
            get: {
                policy.override(forHost: host)[keyPath: keyPath] ?? defaultValue
            },
            set: { newValue in
                var override = policy.override(forHost: host)
                override[keyPath: keyPath] = newValue == defaultValue ? nil : newValue
                policy.setOverride(override, forHost: host)
                onChanged()
            }
        )
    }
}
