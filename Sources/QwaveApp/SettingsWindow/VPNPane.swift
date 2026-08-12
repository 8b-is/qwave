import SwiftUI
import VPNKit

/// Mullvad VPN: account, relay selection, quantum-resistance toggle,
/// tunnel install + connect controls.
struct VPNPane: View {
    @ObservedObject var vpn: MullvadVPNService
    @ObservedObject var tunnel: TunnelManager
    @State private var accountNumber = ""
    @State private var selectedCountry = ""
    @State private var extensionStatus = ""

    @MainActor
    init(vpn: MullvadVPNService) {
        self.vpn = vpn
        self.tunnel = vpn.tunnel
    }

    var body: some View {
        Form {
            Section("Account") {
                if vpn.account.isLoggedIn {
                    LabeledContent("Device", value: vpn.account.deviceName ?? "—")
                    if let expiry = vpn.account.accountExpiry {
                        LabeledContent("Paid until", value: expiry.formatted(date: .abbreviated, time: .omitted))
                    }
                    Button("Log Out & Remove Device") {
                        Task { await vpn.logout() }
                    }
                } else {
                    SecureField("Mullvad account number", text: $accountNumber)
                        .textFieldStyle(.roundedBorder)
                    Button(vpn.isBusy ? "Logging in…" : "Log In") {
                        Task {
                            if await vpn.login(accountNumber: accountNumber) {
                                accountNumber = ""
                                await vpn.loadRelays()
                            }
                        }
                    }
                    .disabled(vpn.isBusy || accountNumber.isEmpty)
                }
            }

            Section("Relay") {
                Picker("Country", selection: $selectedCountry) {
                    Text("Any country").tag("")
                    ForEach(vpn.availableCountries, id: \.code) { country in
                        Text(country.name).tag(country.code)
                    }
                }
                .onChange(of: selectedCountry) { _, newValue in
                    vpn.constraints.location = newValue.isEmpty ? nil : newValue
                }
                Toggle("Mullvad-owned servers only", isOn: $vpn.constraints.ownedOnly)
                Toggle("Require DAITA (traffic-analysis defense)", isOn: $vpn.constraints.requireDaita)
                Toggle("Quantum-resistant tunnel", isOn: $vpn.quantumResistant)
                if vpn.relayList == nil {
                    Button("Load relay list") {
                        Task { await vpn.loadRelays() }
                    }
                }
            }

            Section("Tunnel") {
                LabeledContent("Status", value: statusText)
                HStack {
                    Button(connectTitle) {
                        Task { await vpn.connect() }
                    }
                    .disabled(!vpn.account.isLoggedIn || vpn.isBusy || isConnected)
                    Button("Disconnect") {
                        vpn.disconnect()
                    }
                    .disabled(!isConnected && tunnel.state != .connecting)
                }
                Button("Install VPN System Extension…") {
                    extensionStatus = "Requesting activation…"
                    SystemExtensionActivator.shared.activate { status in
                        extensionStatus = status
                    }
                }
                if !extensionStatus.isEmpty {
                    Text(extensionStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = vpn.lastError ?? tunnel.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .onAppear {
            selectedCountry = vpn.constraints.location ?? ""
            Task { await vpn.tunnel.refresh() }
        }
    }

    private var isConnected: Bool {
        if case .connected = tunnel.state { return true }
        return false
    }

    private var connectTitle: String {
        tunnel.state == .connecting ? "Connecting…" : "Connect"
    }

    private var statusText: String {
        switch tunnel.state {
        case .notInstalled: return "Tunnel not installed (build unsigned, or extension not activated)"
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected(let relay): return "Connected via \(relay ?? "Mullvad")"
        case .disconnecting: return "Disconnecting…"
        case .reasserting: return "Reconnecting…"
        case .invalid: return "Configuration invalid"
        }
    }
}
