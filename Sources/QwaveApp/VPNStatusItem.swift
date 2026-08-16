import AppKit
import Combine
import VPNKit

// `TunnelStatsSampler` lived here: a 1.5-second timer that polled
// `TunnelManager.requestStats()` and rendered "↑ x/s ↓ y/s" into the menu bar.
// It never showed anything but zero, for two compounding reasons (issue #135):
// the provider answered with the Zig packet filter's counters, and that filter
// has no caller, so the counters could not be anything but zero; and the reply
// was JSON while the parser looked for WireGuard `tx_bytes=` UAPI lines, so even
// a real number would not have arrived. A menu-bar readout pinned at zero is
// worse than no readout, because it looks like a measurement of an idle tunnel.
// Removed rather than relabelled — there is no honest label for it.

private extension VPNState {
    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// Menu-bar shield: tunnel state at a glance and a one-click server switcher
/// built from the relay list.
@MainActor
final class VPNStatusItem: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let vpn: MullvadVPNService
    private var cancellable: AnyCancellable?
    private var relayList: RelayList?

    init(vpn: MullvadVPNService) {
        self.vpn = vpn
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon(for: vpn.tunnel.state)

        cancellable = vpn.tunnel.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                MainActor.assumeIsolated { self?.stateChanged(state) }
            }
    }

    private func stateChanged(_ state: VPNState) {
        updateIcon(for: state)
        if state.isConnected, relayList == nil {
            Task {
                await vpn.loadRelays(); relayList = vpn.relayList
            }
        }
    }

    private func updateIcon(for state: VPNState) {
        let symbol: String
        let description: String
        switch state {
        case .connected:
            symbol = "lock.shield.fill"
            description = "VPN connected"
        case .connecting, .reasserting:
            symbol = "shield.lefthalf.filled"
            description = "VPN connecting"
        default:
            symbol = "shield.slash"
            description = "VPN off"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.toolTip = description
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let statusLine: String
        switch vpn.tunnel.state {
        case .connected(let relay): statusLine = "Connected via \(relay ?? "Mullvad")"
        case .connecting: statusLine = "Connecting…"
        case .reasserting: statusLine = "Reconnecting…"
        case .disconnecting: statusLine = "Disconnecting…"
        case .disconnected: statusLine = "Disconnected"
        case .notInstalled: statusLine = "VPN not installed"
        case .invalid: statusLine = "VPN configuration invalid"
        }
        let statusMenuItem = menu.addItem(withTitle: statusLine, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false

        if vpn.tunnel.state.isConnected {
            // A "Sent x · Received y" line stood here, fed by the same
            // always-zero source as the title, and guarded by `> 0` — so it had
            // never once been shown. See the note at the top of this file.
            menu.addItem(.separator())
            menu.addItem(withTitle: "Disconnect", action: #selector(disconnect(_:)), keyEquivalent: "").target = self
        } else if vpn.account.isLoggedIn {
            menu.addItem(withTitle: "Connect", action: #selector(connect(_:)), keyEquivalent: "").target = self
        }

        addServerSwitcher(to: menu)
        menu.addItem(.separator())
        menu.addItem(withTitle: "VPN Settings…", action: #selector(openSettings(_:)), keyEquivalent: "").target = self
    }

    /// One-click server switcher: a country submenu per available country
    /// (top relays only, to keep the menu usable), plus "Fastest" quick pick.
    private func addServerSwitcher(to menu: NSMenu) {
        guard vpn.account.isLoggedIn else { return }
        let list = relayList ?? vpn.relayList
        guard let list else { return }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Server", action: nil, keyEquivalent: "").isEnabled = false

        let fastestItem = menu.addItem(
            withTitle: "⚡ Fastest available", action: #selector(connectFastest(_:)), keyEquivalent: "")
        fastestItem.target = self
        fastestItem.isEnabled = !vpn.isBusy

        for (code, name) in vpn.availableCountries.prefix(12) {
            let relays = RelaySelector.matchingRelays(in: list, constraints: RelayConstraints(location: code))
                .prefix(6)
            guard !relays.isEmpty else { continue }
            let submenu = NSMenu()
            for relay in relays {
                let title = "\(relay.hostname)\(relay.owned ? " · owned" : "")"
                let item = submenu.addItem(withTitle: title, action: #selector(connectToRelay(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = relay.location
            }
            let header = menu.addItem(withTitle: name, action: nil, keyEquivalent: "")
            menu.setSubmenu(submenu, for: header)
        }
    }

    @objc private func connect(_ sender: Any?) {
        Task { await vpn.connect() }
    }

    @objc private func connectFastest(_ sender: Any?) {
        vpn.constraints.location = nil
        Task { await vpn.connect() }
    }

    @objc private func connectToRelay(_ sender: NSMenuItem) {
        guard let location = sender.representedObject as? String else { return }
        vpn.constraints.location = location
        Task { await vpn.connect() }
    }

    @objc private func disconnect(_ sender: Any?) {
        vpn.disconnect()
    }

    @objc private func openSettings(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.showSettings(sender)
    }
}
