import SwiftUI
import FeatureFlags

/// Safari Technology Preview-style experimental feature toggles.
struct FeatureFlagsPane: View {
    @ObservedObject var service: FeatureFlagService
    @State private var searchText = ""
    @State private var showInternal = false

    private var visibleFeatures: [WebFeature] {
        service.features.filter { feature in
            let statusOK = showInternal || feature.status.isUserFacing
            let searchOK =
                searchText.isEmpty
                || feature.name.localizedCaseInsensitiveContains(searchText)
                || feature.key.localizedCaseInsensitiveContains(searchText)
            return statusOK && searchOK
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !service.isSPIAvailable {
                switch service.surfaceState {
                case .unavailable:
                    ContentUnavailableView(
                        "WebKit feature flags unavailable",
                        systemImage: "flask",
                        description: Text("This WebKit build doesn't expose the feature SPI. Browsing is unaffected.")
                    )
                case .emptySurface:
                    ContentUnavailableView(
                        "WebKit feature flags unavailable",
                        systemImage: "flask",
                        description: Text(
                            "This WebKit build reports no toggleable features"
                                + (FeatureFlagService.webKitVersionString.map { " (WebKit \($0))." } ?? ".")
                                + " Browsing is unaffected."
                        )
                    )
                case .available:
                    EmptyView()  // unreachable: isSPIAvailable is true here
                }
            } else {
                HStack {
                    TextField("Filter features", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Show internal", isOn: $showInternal)
                        .toggleStyle(.checkbox)
                    Button("Reset All") {
                        service.resetAll()
                    }
                    .disabled(service.overriddenCount == 0)
                }

                Text("Toggles apply to new tabs. \(service.overriddenCount) overridden.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                List(visibleFeatures) { feature in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(feature.name)
                                    .fontWeight(feature.isEnabled != feature.defaultValue ? .semibold : .regular)
                                Text(feature.status.displayName)
                                    .font(.caption2)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(.quaternary, in: Capsule())
                            }
                            if let details = feature.details, !details.isEmpty {
                                Text(details)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { feature.isEnabled },
                                set: { service.setEnabled($0, forKey: feature.key) }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(16)
    }
}
