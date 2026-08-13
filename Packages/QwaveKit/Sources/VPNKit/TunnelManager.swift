// NetworkExtension and Foundation vend non-Sendable reference types this
// @MainActor manager must pass across await boundaries — NETunnelProviderManager
// from `loadAllFromPreferences()` and Notification from the NEVPNStatusDidChange
// async sequence. Neither SDK is Sendable-annotated yet, so @preconcurrency
// downgrades those specific cross-actor diagnostics to warnings instead of
// hiding them behind @unchecked Sendable on our own types. Required by Swift
// 6.1 (CI authority); Swift 6.3 (local) is more permissive and would not flag.
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
            for await notification in NotificationCenter.default.notifications(
                named: .NEVPNStatusDidChange,
                object: connection
            ) {
                guard !Task.isCancelled, (notification.object as AnyObject?) === connection else { return }
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

    /// Session stats via provider messages ("stats" → tx/rx/handshake text).
    public func requestStats() async -> String? {
        guard let session = manager?.connection as? NETunnelProviderSession,
            manager?.connection.status == .connected
        else { return nil }
        return await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(Data("stats".utf8)) { response in
                    continuation.resume(returning: response.flatMap { String(data: $0, encoding: .utf8) })
                }
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NEVPNErrorDomain {
            return
                "VPN configuration error (\(nsError.code)). Is the tunnel extension installed and signed? See docs/SIGNING.md."
        }
        return nsError.localizedDescription
    }
}
