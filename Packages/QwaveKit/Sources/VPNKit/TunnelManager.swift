// NetworkExtension and Foundation vend non-Sendable reference types this
// @MainActor manager must pass across await boundaries — notably
// NETunnelProviderManager from `loadAllFromPreferences()`. Neither SDK is
// Sendable-annotated yet, so @preconcurrency downgrades those specific
// cross-actor diagnostics to warnings instead of hiding them behind
// @unchecked Sendable on our own types. Required by Swift 6.1 (CI authority);
// Swift 6.3 (local) is more permissive and would not flag. The
// NEVPNStatusDidChange async sequence needs a separate fix (see adopt(manager:)):
// @preconcurrency cannot reach diagnostics raised by the concurrency library.
@preconcurrency import Foundation
@preconcurrency import NetworkExtension
import Combine
import QwaveSupport

public enum VPNState: Equatable, Sendable {
    /// No tunnel configuration exists yet (or the extension isn't installed/signed).
    case notInstalled
    case disconnected
    case connecting
    case connected(relayHostname: String?)
    case disconnecting
    case reasserting
    case invalid
}

/// Owns the `NETunnelProviderManager` for Qwave's packet tunnel: creates and
/// saves the configuration, starts/stops the tunnel, and publishes status for
/// the UI. On an unsigned development build every NE call fails cleanly and
/// the state stays `.notInstalled` — the browser is unaffected.
@MainActor
public final class TunnelManager: ObservableObject {
    @Published public private(set) var state: VPNState = .notInstalled
    @Published public private(set) var lastError: String?

    public let providerBundleIdentifier: String
    private let localizedDescription: String

    private var manager: NETunnelProviderManager?
    private var statusObserverTask: Task<Void, Never>?
    private var currentRelayHostname: String?

    public init(
        providerBundleIdentifier: String = "is.8b.qwave.tunnel",
        localizedDescription: String = "Qwave Mullvad VPN"
    ) {
        self.providerBundleIdentifier = providerBundleIdentifier
        self.localizedDescription = localizedDescription
    }

    deinit {
        statusObserverTask?.cancel()
    }

    // MARK: - Preferences

    /// Loads the existing configuration, if any, and begins observing status.
    public func refresh() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            let ours = managers.first { manager in
                (manager.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == providerBundleIdentifier
            }
            if let ours {
                adopt(manager: ours)
            } else {
                state = .notInstalled
            }
        } catch {
            lastError = error.localizedDescription
            state = .notInstalled
        }
    }

    private func adopt(manager: NETunnelProviderManager) {
        self.manager = manager
        statusObserverTask?.cancel()
        let connection = manager.connection
        statusObserverTask = Task { @MainActor [weak self] in
            // `Notification` is non-Sendable, and on Swift 6.1 returning it from
            // `AsyncIteratorProtocol.next()` into this @MainActor task is an error
            // that @preconcurrency on the Foundation import cannot downgrade — the
            // diagnostic comes from the concurrency library's generic machinery, not
            // from Foundation. We only need the "status changed" edge: the sequence
            // is already filtered to `object: connection`, and syncState() re-reads
            // the live status. Mapping each notification to Void keeps every
            // non-Sendable value on the nonisolated side of the boundary.
            let statusChanges = NotificationCenter.default.notifications(
                named: .NEVPNStatusDidChange,
                object: connection
            ).map { _ in () }
            for await _ in statusChanges {
                guard !Task.isCancelled else { return }
                self?.syncState()
            }
        }
        syncState()
    }

    private func syncState() {
        guard let manager else {
            state = .notInstalled
            return
        }
        switch manager.connection.status {
        case .invalid: state = .invalid
        case .disconnected: state = .disconnected
        case .connecting: state = .connecting
        case .connected: state = .connected(relayHostname: currentRelayHostname)
        case .reasserting: state = .reasserting
        case .disconnecting: state = .disconnecting
        @unknown default: state = .invalid
        }
    }

    // MARK: - Connect / disconnect

    public func connect(with config: TunnelSessionConfig) async throws {
        lastError = nil
        currentRelayHostname = config.relayHostname

        let manager: NETunnelProviderManager
        if let existing = self.manager {
            manager = existing
        } else {
            let managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
            manager =
                managers.first { m in
                    (m.protocolConfiguration as? NETunnelProviderProtocol)?
                        .providerBundleIdentifier == providerBundleIdentifier
                } ?? NETunnelProviderManager()
        }

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = providerBundleIdentifier
        proto.serverAddress = config.relayHostname
        proto.providerConfiguration = try config.providerConfiguration()

        manager.protocolConfiguration = proto
        manager.localizedDescription = localizedDescription
        manager.isEnabled = true

        do {
            try await manager.saveToPreferences()
            // NE quirk: a freshly saved manager must be reloaded before start.
            try await manager.loadFromPreferences()
            adopt(manager: manager)
            try manager.connection.startVPNTunnel()
        } catch {
            lastError = Self.describe(error)
            QwaveLog.vpn.error("Tunnel start failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    public func disconnect() {
        manager?.connection.stopVPNTunnel()
    }

    // No `requestStats()`. It sent "stats" to the packet-tunnel provider, whose
    // answer was the Zig packet filter's counters — a filter with no caller, so
    // every counter was structurally zero (issue #135). Worse, the one consumer
    // parsed the reply as WireGuard `tx_bytes=`/`rx_bytes=` UAPI text, which the
    // JSON reply never contained, so the menu bar had been reporting a hard-coded
    // "↑ 0 B/s ↓ 0 B/s" for its whole life. Both ends are withdrawn rather than
    // patched: `WireGuardAdapter.getRuntimeConfiguration` (already used inside the
    // provider for handshake confirmation) is where a real throughput readout
    // would come from, and wiring that up is a product change, not a bug fix.

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NEVPNErrorDomain {
            return
                "VPN configuration error (\(nsError.code)). Is the tunnel extension installed and signed? See docs/SIGNING.md."
        }
        return nsError.localizedDescription
    }
}
