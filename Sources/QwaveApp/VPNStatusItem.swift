import AppKit
import Combine
import VPNKit

/// Menu-bar shield: shows tunnel state at a glance, quick connect/disconnect.
@MainActor
final class VPNStatusItem: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let vpn: MullvadVPNService
    private var cancellable: AnyCancellable?

    init(vpn: MullvadVPNService) {
        self.vpn = vpn
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon(for: vpn.tunnel.state)

        cancellable = vpn.tunnel.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                MainActor.assumeIsolated {
                    self?.updateIcon(for: state)
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
        menu.addItem(.separator())

        if case .connected = vpn.tunnel.state {
            menu.addItem(withTitle: "Disconnect", action: #selector(disconnect(_:)), keyEquivalent: "").target = self
        } else if vpn.account.isLoggedIn {
            menu.addItem(withTitle: "Connect", action: #selector(connect(_:)), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "VPN Settings…", action: #selector(openSettings(_:)), keyEquivalent: "").target = self
    }

    @objc private func connect(_ sender: Any?) {
        Task { await vpn.connect() }
    }

    @objc private func disconnect(_ sender: Any?) {
        vpn.disconnect()
    }

    @objc private func openSettings(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.showSettings(sender)
    }
}
