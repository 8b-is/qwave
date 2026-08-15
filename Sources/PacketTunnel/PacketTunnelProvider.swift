import Foundation
// NetworkExtension is not concurrency-audited: NEPacketTunnelProvider's
// startTunnel/stopTunnel completion handlers import as non-Sendable, so the
// @Sendable handlers these overrides need (they are captured by a Task and by
// WireGuardAdapter callbacks) would otherwise be a sendability mismatch under
// Swift 6.
@preconcurrency import NetworkExtension
import WireGuardKit
import VPNKit
import QwaveSupport

// Zig packet filter (zig-core/src/packet.zig, built via preBuildScript).
// C function declarations — the header is included as a target source.
private let QPACKET_ALLOW: Int32 = 0
private let QPACKET_DROP: Int32 = 1

@_silgen_name("qpacket_filter_init")
private func qpacket_filter_init() -> UnsafeMutableRawPointer?

@_silgen_name("qpacket_filter")
private func qpacket_filter(_ state: UnsafeMutableRawPointer?, _ packet: UnsafePointer<UInt8>?, _ len: Int) -> Int32

@_silgen_name("qpacket_filter_stats")
private func qpacket_filter_stats(
    _ state: UnsafeMutableRawPointer?,
    _ seen: UnsafeMutablePointer<UInt64>,
    _ dropped: UnsafeMutablePointer<UInt64>
)

@_silgen_name("qpacket_filter_stats_extended")
private func qpacket_filter_stats_extended(
    _ state: UnsafeMutableRawPointer?,
    _ stats: UnsafeMutablePointer<QpacketStats>
)

@_silgen_name("qpacket_filter_deinit")
private func qpacket_filter_deinit(_ state: UnsafeMutableRawPointer?)

/// C-compatible struct mirroring the Zig PacketStats.
private struct QpacketStats {
    var packets_seen: UInt64
    var packets_dropped: UInt64
    var packets_tcp: UInt64
    var packets_udp: UInt64
    var packets_icmp: UInt64
    var packets_other: UInt64
    var packets_ipv4: UInt64
    var packets_ipv6: UInt64
    var bytes_seen: UInt64
}

enum PacketTunnelError: Error {
    case missingConfiguration
    case missingPrivateKey
    case invalidConfiguration(String)
    case filterInitFailed
}

private final class TunnelProviderReference: @unchecked Sendable {
    weak var value: NEPacketTunnelProvider?

    init(value: NEPacketTunnelProvider) {
        self.value = value
    }
}

private final class MessageCompletion: @unchecked Sendable {
    let handler: ((Data?) -> Void)?

    init(_ handler: ((Data?) -> Void)?) {
        self.handler = handler
    }
}

private actor PacketTunnelState {
    private let negotiator: EphemeralPeerNegotiating = MullvadQuantumPeerNegotiator()
    private let secrets = KeychainSecretStore()
    private let adapter: WireGuardAdapter

    /// How long to wait for a corroborating handshake before rolling a
    /// rekey back (issue #91). Bounded well under `REJECT_AFTER_TIME`
    /// (~180s), so a rollback still lands before the existing session keys
    /// would otherwise age out.
    private static let rekeyConfirmationAttempts = 5
    private static let rekeyConfirmationPollInterval: TimeInterval = 2

    private var filterHandle: UnsafeMutableRawPointer?
    private var sessionConfig: TunnelSessionConfig?
    private var baseConfiguration: TunnelConfiguration?
    /// The configuration (including PSK) currently installed on the
    /// adapter. Snapshotted before every rekey attempt so an unconfirmed
    /// rekey can be rolled back instead of leaving a tampered PSK in place.
    private var activeConfiguration: TunnelConfiguration?
    private var lastRekey: Date?
    private var rekeyTimer: DispatchSourceTimer?

    init(provider: TunnelProviderReference) {
        guard let provider = provider.value else {
            fatalError("Packet tunnel provider must outlive its state actor")
        }
        adapter = WireGuardAdapter(with: provider) { level, message in
            switch level {
            case .error:
                QwaveLog.tunnel.error("\(message, privacy: .public)")
            case .verbose:
                QwaveLog.tunnel.debug("\(message, privacy: .public)")
            }
        }
    }

    func start(
        sessionConfig: TunnelSessionConfig,
        completionHandler: @escaping @Sendable (Error?) -> Void
    ) async {
        guard let keyData = try? secrets.secret(for: DeviceKeyManager.privateKeyStorageKey),
            let privateKey = PrivateKey(rawValue: keyData)
        else {
            completionHandler(PacketTunnelError.missingPrivateKey)
            return
        }

        if filterHandle == nil {
            guard let handle = qpacket_filter_init() else {
                completionHandler(PacketTunnelError.filterInitFailed)
                return
            }
            filterHandle = handle
            QwaveLog.tunnel.info("Zig packet filter initialised")
        }

        do {
            var tunnelConfiguration = try PacketTunnelProvider.makeTunnelConfiguration(
                sessionConfig: sessionConfig,
                privateKey: privateKey
            )
            let base = tunnelConfiguration
            var negotiatedAt: Date?
            if let material = try await negotiator.negotiateFailClosed(config: sessionConfig),
                let peer = tunnelConfiguration.peers.first
            {
                var pskPeer = peer
                pskPeer.preSharedKey = PreSharedKey(rawValue: material.presharedKey)
                tunnelConfiguration = TunnelConfiguration(
                    name: tunnelConfiguration.name,
                    interface: tunnelConfiguration.interface,
                    peers: [pskPeer]
                )
                negotiatedAt = Date()
            }

            let error = await startAdapter(tunnelConfiguration)
            if let error {
                QwaveLog.tunnel.error("Adapter start failed: \(error.localizedDescription, privacy: .public)")
            } else {
                self.sessionConfig = sessionConfig
                self.baseConfiguration = base
                self.activeConfiguration = tunnelConfiguration
                self.lastRekey = negotiatedAt
                if negotiatedAt != nil {
                    scheduleRekeyTimer()
                }
                QwaveLog.tunnel.info("Tunnel up via \(sessionConfig.relayHostname, privacy: .public)")
            }
            completionHandler(error)
        } catch {
            QwaveLog.tunnel.error("Tunnel start blocked: \(error.localizedDescription, privacy: .public)")
            completionHandler(error)
        }
    }

    func stop(completionHandler: @escaping @Sendable () -> Void) async {
        rekeyTimer?.cancel()
        rekeyTimer = nil
        sessionConfig = nil
        baseConfiguration = nil
        activeConfiguration = nil
        lastRekey = nil
        if let handle = filterHandle {
            qpacket_filter_deinit(handle)
            filterHandle = nil
            QwaveLog.tunnel.info("Zig packet filter torn down")
        }
        _ = await stopAdapter()
        completionHandler()
    }

    func wake() async {
        guard RekeyPolicy.shouldRekey(lastRekey: lastRekey) else { return }
        await rekeyNow()
    }

    func response(for messageData: Data) -> Data? {
        guard String(data: messageData, encoding: .utf8) == "stats" else { return nil }
        var stats = QpacketStats(
            packets_seen: 0, packets_dropped: 0, packets_tcp: 0,
            packets_udp: 0, packets_icmp: 0, packets_other: 0,
            packets_ipv4: 0, packets_ipv6: 0, bytes_seen: 0
        )
        if let handle = filterHandle {
            qpacket_filter_stats_extended(handle, &stats)
        }
        let json = """
            {"packets_seen":\(stats.packets_seen),"packets_dropped":\(stats.packets_dropped),\
            "packets_tcp":\(stats.packets_tcp),"packets_udp":\(stats.packets_udp),\
            "packets_icmp":\(stats.packets_icmp),"packets_ipv4":\(stats.packets_ipv4),\
            "packets_ipv6":\(stats.packets_ipv6),"bytes_seen":\(stats.bytes_seen)}
            """
        return Data(json.utf8)
    }

    private func scheduleRekeyTimer() {
        rekeyTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // Generous leeway: exact rotation time doesn't matter, extra wakeups do.
        timer.schedule(
            deadline: .now() + RekeyPolicy.interval,
            repeating: RekeyPolicy.interval,
            leeway: .seconds(15 * 60)
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.rekeyNow() }
        }
        timer.resume()
        rekeyTimer = timer
    }

    /// Negotiates a fresh ephemeral PSK and installs it via
    /// `WireGuardAdapter.update`, then waits (bounded) for a corroborating
    /// handshake before committing to it — see `RekeyConfirmation` (issue
    /// #91). ML-KEM's implicit rejection means `negotiator` never throws on
    /// a tampered ciphertext; it just returns a wrong secret, so the adapter
    /// update above always "succeeds" whether or not the PSK is the one the
    /// relay holds. If no handshake confirms the new PSK within the window,
    /// the previous configuration is restored and `lastRekey` is *not*
    /// advanced, so the rekey retries at the next timer tick or wake —
    /// exactly the retry behaviour a throwing negotiation gets.
    private func rekeyNow() async {
        guard let sessionConfig, let baseConfiguration, sessionConfig.quantumResistant else { return }
        do {
            guard let material = try await negotiator.negotiateFailClosed(config: sessionConfig),
                let peer = baseConfiguration.peers.first
            else { return }
            var pskPeer = peer
            pskPeer.preSharedKey = PreSharedKey(rawValue: material.presharedKey)
            let updated = TunnelConfiguration(
                name: baseConfiguration.name,
                interface: baseConfiguration.interface,
                peers: [pskPeer]
            )

            let rollbackConfiguration = activeConfiguration ?? baseConfiguration
            let baselineHandshake = await lastHandshakeTime()

            if let error = await updateAdapter(updated) {
                QwaveLog.tunnel.error(
                    "Rekey update failed; keeping current PSK: \(error.localizedDescription, privacy: .public)")
                return
            }

            if await waitForHandshakeConfirmation(after: baselineHandshake) {
                activeConfiguration = updated
                QwaveLog.tunnel.info("Ephemeral peer PSK rotated")
                lastRekey = Date()
            } else {
                QwaveLog.tunnel.error("Rekey PSK unconfirmed (no handshake seen); rolling back")
                if let error = await updateAdapter(rollbackConfiguration) {
                    QwaveLog.tunnel.error(
                        "Rekey rollback failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        } catch {
            QwaveLog.tunnel.error(
                "Rekey negotiation failed; keeping current PSK: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Polls the adapter's runtime config for a handshake newer than
    /// `baseline`, bounded by `rekeyConfirmationAttempts` × `..PollInterval`.
    private func waitForHandshakeConfirmation(after baseline: Date?) async -> Bool {
        for _ in 0..<Self.rekeyConfirmationAttempts {
            try? await Task.sleep(nanoseconds: UInt64(Self.rekeyConfirmationPollInterval * 1_000_000_000))
            let observed = await lastHandshakeTime()
            if RekeyConfirmation.isConfirmed(baseline: baseline, observed: observed) {
                return true
            }
        }
        return false
    }

    /// The peer's `last_handshake_time_sec`, read from the adapter's live
    /// UAPI config (see `WireGuardAdapter.getRuntimeConfiguration`). `nil` on
    /// any read failure or if no handshake has ever completed. This parses
    /// only the one field the corroboration check needs — the full UAPI
    /// parser (`TunnelConfiguration(fromUapiConfig:)`) lives in WireGuardApp,
    /// a wg-quick/UI helper that is not part of the extension's linked
    /// module.
    private func lastHandshakeTime() async -> Date? {
        let uapi = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            adapter.getRuntimeConfiguration { continuation.resume(returning: $0) }
        }
        guard let uapi else { return nil }
        for line in uapi.split(separator: "\n") {
            guard let equalsIndex = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equalsIndex])
            guard key == "last_handshake_time_sec" else { continue }
            let value = String(line[line.index(after: equalsIndex)...])
            guard let seconds = UInt64(value), seconds != 0 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(seconds))
        }
        return nil
    }

    private func startAdapter(_ configuration: TunnelConfiguration) async -> WireGuardAdapterError? {
        await withCheckedContinuation { continuation in
            adapter.start(tunnelConfiguration: configuration) { error in
                continuation.resume(returning: error)
            }
        }
    }

    private func stopAdapter() async -> WireGuardAdapterError? {
        await withCheckedContinuation { continuation in
            adapter.stop { error in
                continuation.resume(returning: error)
            }
        }
    }

    private func updateAdapter(_ configuration: TunnelConfiguration) async -> WireGuardAdapterError? {
        await withCheckedContinuation { continuation in
            adapter.update(tunnelConfiguration: configuration) { error in
                continuation.resume(returning: error)
            }
        }
    }

}

/// WireGuard packet tunnel. The app hands over a `TunnelSessionConfig` via
/// providerConfiguration; the device private key is resolved from the shared
/// keychain (never crosses the app/extension boundary in the config), and the
/// quantum-resistant PSK seam (`EphemeralPeerNegotiating`) runs before the
/// tunnel handshake — Stage A's noop keeps this classic WireGuard.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private lazy var tunnelState = PacketTunnelState(provider: TunnelProviderReference(value: self))

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping @Sendable (Error?) -> Void
    ) {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
            let sessionConfig = TunnelSessionConfig(providerConfiguration: proto.providerConfiguration)
        else {
            completionHandler(PacketTunnelError.missingConfiguration)
            return
        }
        let state = tunnelState
        Task {
            await state.start(sessionConfig: sessionConfig, completionHandler: completionHandler)
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping @Sendable () -> Void
    ) {
        let state = tunnelState
        Task {
            await state.stop(completionHandler: completionHandler)
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    override func wake() {
        let state = tunnelState
        Task {
            await state.wake()
        }
    }

    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)? = nil
    ) {
        let state = tunnelState
        let completion = MessageCompletion(completionHandler)
        Task {
            completion.handler?(await state.response(for: messageData))
        }
    }

    // MARK: - Configuration mapping

    static func makeTunnelConfiguration(
        sessionConfig: TunnelSessionConfig,
        privateKey: PrivateKey
    ) throws -> TunnelConfiguration {
        var interface = InterfaceConfiguration(privateKey: privateKey)
        interface.addresses = sessionConfig.interfaceAddresses.compactMap(IPAddressRange.init(from:))
        guard !interface.addresses.isEmpty else {
            throw PacketTunnelError.invalidConfiguration("no valid interface addresses")
        }
        interface.dns = sessionConfig.dnsServers.compactMap(DNSServer.init(from:))

        guard let publicKey = PublicKey(base64Key: sessionConfig.peerPublicKeyBase64) else {
            throw PacketTunnelError.invalidConfiguration("bad peer public key")
        }
        var peer = PeerConfiguration(publicKey: publicKey)
        guard let endpoint = Endpoint(from: sessionConfig.peerEndpoint) else {
            throw PacketTunnelError.invalidConfiguration("bad endpoint \(sessionConfig.peerEndpoint)")
        }
        peer.endpoint = endpoint
        peer.allowedIPs = sessionConfig.allowedIPs.compactMap(IPAddressRange.init(from:))
        peer.persistentKeepAlive = 25

        return TunnelConfiguration(
            name: sessionConfig.relayHostname,
            interface: interface,
            peers: [peer]
        )
    }
}
