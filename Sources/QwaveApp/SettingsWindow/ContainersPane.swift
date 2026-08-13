import SwiftUI
import BrowserCore
import Persistence

/// Manage container profiles (Firefox-style isolated storage universes).
struct ContainersPane: View {
    @ObservedObject var containers: ContainerRegistry
    let history: HistoryStore?

    @State private var newName = ""
    @State private var newColor = Color.blue
    @State private var deletingProfile: ContainerProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                "Each container is a fully isolated storage universe — separate cookies, logins, caches, and site data. Deleting a container wipes everything sites stored in it."
            )
            .font(.callout)
            .foregroundStyle(.secondary)

            List {
                ForEach(containers.profiles) { profile in
                    HStack {
                        Circle()
                            .fill(Color(nsColor: NSColor(hexString: profile.colorHex) ?? .systemGray))
                            .frame(width: 12, height: 12)
                        Text(profile.name)
                        Spacer()
                        Button(role: .destructive) {
                            deletingProfile = profile
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 2)
                }
            }

            HStack {
                TextField("New container name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                ColorPicker("", selection: $newColor, supportsOpacity: false)
                    .labelsHidden()
                Button("Add Container") {
                    let trimmed = newName.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    containers.createProfile(name: trimmed, colorHex: newColor.hexString)
                    newName = ""
                }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .alert(
            "Delete container “\(deletingProfile?.name ?? "")”?",
            isPresented: Binding(get: { deletingProfile != nil }, set: { if !$0 { deletingProfile = nil } })
        ) {
            Button("Delete & Wipe Data", role: .destructive) {
                if let profile = deletingProfile {
                    let id = profile.id
                    Task { @MainActor in
                        await containers.deleteProfile(id: id)
                        try? history?.deleteAll(containerID: id)
                    }
                }
                deletingProfile = nil
            }
            Button("Cancel", role: .cancel) {
                deletingProfile = nil
            }
        } message: {
            Text("All cookies, logins, and site data stored in this container will be permanently removed.")
        }
    }
}

private extension Color {
    var hexString: String {
        let nsColor = NSColor(self).usingColorSpace(.sRGB) ?? .systemBlue
        let red = Int(round(nsColor.redComponent * 255))
        let green = Int(round(nsColor.greenComponent * 255))
        let blue = Int(round(nsColor.blueComponent * 255))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
