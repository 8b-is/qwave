import AppKit
import Combine
import VPNKit

/// Live tunnel throughput sampler: polls the packet tunnel provider for
/// WireGuard runtime stats and computes bytes/second deltas.
@MainActor
final class TunnelStatsSampler {
    struct Sample: Equatable {
        var txBytes: UInt64 = 0
        var rxBytes: UInt64 = 0
        var txRate: Double = 0
        var rxRate: Double = 0
    }

    private let tunnel: TunnelManager
    private var timer: Timer?
    private var last: (tx: UInt64, rx: UInt64, date: Date)?
    private(set) var sample = Sample()

    init(tunnel: TunnelManager) {
        self.tunnel = tunnel
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        last = nil
    }

    private func tick() {
        guard tunnel.state.isConnected else {
            last = nil
            sample = Sample()
            return
        }
        Task {
            guard let stats = await tunnel.requestStats() else { return }
            let parsed = Self.parse(stats)
            let now = Date()
            if let last, now.timeIntervalSince(last.date) > 0.5 {
                let dt = now.timeIntervalSince(last.date)
                sample = Sample(
                    txBytes: parsed.tx,
                    rxBytes: parsed.rx,
                    txRate: Double(parsed.tx - last.tx) / dt,
                    rxRate: Double(parsed.rx - last.rx) / dt
                )
            } else {
                sample = Sample(txBytes: parsed.tx, rxBytes: parsed.rx)
            }
            last = (parsed.tx, parsed.rx, now)
        }
    }

    /// WireGuard runtime config lines look like `tx_bytes=123 rx_bytes=456
    /// latest_handshake=...` (the adapter's getRuntimeConfiguration output).
    static func parse(_ runtimeConfig: String) -> (tx: UInt64, rx: UInt64) {
        var tx: UInt64 = 0
        var rx: UInt64 = 0
        for line in runtimeConfig.components(separatedBy: .newlines) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "tx_bytes": tx = UInt64(parts[1]) ?? 0
            case "rx_bytes": rx = UInt64(parts[1]) ?? 0
            default: break
            }
        }
        return (tx, rx)
    }

    static func format(_ rate: Double) -> String {
        if rate >= 1_048_576 { return String(format: "%.1f MB/s", rate / 1_048_576) }
        if rate >= 1_024 { return String(format: "%.0f KB/s", rate / 1_024) }
        return String(format: "%.0f B/s", rate)
    }

    static func formatTotal(_ bytes: UInt64) -> String {
        if bytes >= 1_048_576 { return String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        if bytes >= 1_024 { return String(format: "%.1f KB", Double(bytes) / 1_024) }
        return "\(bytes) B"
    }
}

private extension VPNState {
    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// Menu-bar shield: tunnel state at a glance, live throughput, and a
/// one-click server switcher built from the relay list.
@MainActor
final class VPNStatusItem: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let vpn: MullvadVPNService
    private let sampler: TunnelStatsSampler
    private var cancellable: AnyCancellable?
    private var relayList: RelayList?

    init(vpn: MullvadVPNService) {
        self.vpn = vpn
        self.sampler = TunnelStatsSampler(tunnel: vpn.tunnel)
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
        updateTitle()
        if state.isConnected {
            sampler.start()
            if relayList == nil {
                Task { await vpn.loadRelays(); relayList = vpn.relayList }
            }
        } else {
            sampler.stop()
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
    }

    /// Live throughput as the status item title while connected.
    private func updateTitle() {
        guard vpn.tunnel.state.isConnected else {
            statusItem.button?.title = ""
            return
        }
        let s = sampler.sample
        statusItem.button?.title = "↑ \(TunnelStatsSampler.format(s.txRate)) ↓ \(TunnelStatsSampler.format(s.rxRate))"
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        updateTitle()

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
            let s = sampler.sample
            if s.txBytes > 0 || s.rxBytes > 0 {
                let statsLine = "Sent \(TunnelStatsSampler.formatTotal(s.txBytes)) · Received \(TunnelStatsSampler.formatTotal(s.rxBytes))"
                let statsItem = menu.addItem(withTitle: statsLine, action: nil, keyEquivalent: "")
                statsItem.isEnabled = false
            }
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

        let fastestItem = menu.addItem(withTitle: "⚡ Fastest available", action: #selector(connectFastest(_:)), keyEquivalent: "")
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
