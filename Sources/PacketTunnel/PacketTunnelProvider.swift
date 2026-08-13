import Foundation
import NetworkExtension
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
private func qpacket_filter_stats(_ state: UnsafeMutableRawPointer?, _ seen: UnsafeMutablePointer<UInt64>, _ dropped: UnsafeMutablePointer<UInt64>)

@_silgen_name("qpacket_filter_deinit")
private func qpacket_filter_deinit(_ state: UnsafeMutableRawPointer?)

enum PacketTunnelError: Error {
    case missingConfiguration
    case missingPrivateKey
    case invalidConfiguration(String)
    case filterInitFailed
}

/// WireGuard packet tunnel. The app hands over a `TunnelSessionConfig` via
/// providerConfiguration; the device private key is resolved from the shared
/// keychain (never crosses the app/extension boundary in the config), and the
/// quantum-resistant PSK seam (`EphemeralPeerNegotiating`) runs before the
/// tunnel handshake — Stage A's noop keeps this classic WireGuard.
class PacketTunnelProvider: NEPacketTunnelProvider {
    private lazy var adapter = WireGuardAdapter(with: self) { level, message in
        switch level {
        case .error:
            QwaveLog.tunnel.error("\(message, privacy: .public)")
        case .verbose:
            QwaveLog.tunnel.debug("\(message, privacy: .public)")
        }
    }

    private let negotiator: EphemeralPeerNegotiating = MullvadQuantumPeerNegotiator()
    private let secrets = KeychainSecretStore()

    // Zig packet filter handle (nil when filter is not active).
    private var filterHandle: UnsafeMutableRawPointer?

    // Rekey state, confined to the main queue (timer + wake both hop there).
    private var sessionConfig: TunnelSessionConfig?
    private var baseConfiguration: TunnelConfiguration?
    private var lastRekey: Date?
    private var rekeyTimer: DispatchSourceTimer?

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
            let sessionConfig = TunnelSessionConfig(providerConfiguration: proto.providerConfiguration)
        else {
            completionHandler(PacketTunnelError.missingConfiguration)
            return
        }

        guard let keyData = try? secrets.secret(for: DeviceKeyManager.privateKeyStorageKey),
            let privateKey = PrivateKey(rawValue: keyData)
        else {
            completionHandler(PacketTunnelError.missingPrivateKey)
            return
        }

        // Initialise the Zig packet filter.
        guard let handle = qpacket_filter_init() else {
            completionHandler(PacketTunnelError.filterInitFailed)
            return
        }
        filterHandle = handle
        QwaveLog.tunnel.info("Zig packet filter initialised")

        Task {
            do {
                var tunnelConfiguration = try Self.makeTunnelConfiguration(
                    sessionConfig: sessionConfig,
                    privateKey: privateKey
                )
                let base = tunnelConfiguration

                // Stage B: quantum-resistant PSK, fail-closed. A negotiation
                // failure aborts tunnel start (QuantumSessionError reaches
                // the app as the start error) — never a silent classic
                // fallback while the user believes they are protected.
                var negotiatedAt: Date?
                if let material = try await self.negotiator.negotiateFailClosed(config: sessionConfig),
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

                let configuration = tunnelConfiguration
                let pskInstalledAt = negotiatedAt
                self.adapter.start(tunnelConfiguration: configuration) { error in
                    if let error {
                        QwaveLog.tunnel.error("Adapter start failed: \(error.localizedDescription, privacy: .public)")
                    } else {
                        QwaveLog.tunnel.info("Tunnel up via \(sessionConfig.relayHostname, privacy: .public)")
                        DispatchQueue.main.async {
                            self.sessionConfig = sessionConfig
                            self.baseConfiguration = base
                            self.lastRekey = pskInstalledAt
                            if pskInstalledAt != nil {
                                self.scheduleRekeyTimer()
                            }
                        }
                    }
                    completionHandler(error)
                }
            } catch {
                QwaveLog.tunnel.error("Tunnel start blocked: \(error.localizedDescription, privacy: .public)")
                completionHandler(error)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        // Tear down the Zig packet filter.
        if let handle = filterHandle {
            qpacket_filter_deinit(handle)
            filterHandle = nil
            QwaveLog.tunnel.info("Zig packet filter torn down")
        }
        DispatchQueue.main.async {
            self.rekeyTimer?.cancel()
            self.rekeyTimer = nil
            self.sessionConfig = nil
            self.baseConfiguration = nil
            self.lastRekey = nil
        }
        adapter.stop { error in
            if let error {
                QwaveLog.tunnel.error("Adapter stop failed: \(error.localizedDescription, privacy: .public)")
            }
            completionHandler()
        }
    }

    // MARK: - Daily ephemeral-peer rekey

    override func sleep(completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    override func wake() {
        DispatchQueue.main.async {
            guard RekeyPolicy.shouldRekey(lastRekey: self.lastRekey) else { return }
            self.rekeyNow()
        }
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
            self?.rekeyNow()
        }
        timer.resume()
        rekeyTimer = timer
    }

    /// Negotiates a fresh ephemeral PSK and installs it via
    /// `WireGuardAdapter.update`. A failed rekey keeps the current PSK (the
    /// tunnel stays quantum-resistant on the previous key) and retries at the
    /// next timer tick or wake — unlike start, there is no downgrade to block.
    private func rekeyNow() {
        guard let sessionConfig, let baseConfiguration, sessionConfig.quantumResistant else { return }
        Task {
            do {
                guard let material = try await self.negotiator.negotiateFailClosed(config: sessionConfig),
                    let peer = baseConfiguration.peers.first
                else { return }
                var pskPeer = peer
                pskPeer.preSharedKey = PreSharedKey(rawValue: material.presharedKey)
                let updated = TunnelConfiguration(
                    name: baseConfiguration.name,
                    interface: baseConfiguration.interface,
                    peers: [pskPeer]
                )
                self.adapter.update(tunnelConfiguration: updated) { error in
                    if let error {
                        QwaveLog.tunnel.error(
                            "Rekey update failed; keeping current PSK: \(error.localizedDescription, privacy: .public)")
                    } else {
                        QwaveLog.tunnel.info("Ephemeral peer PSK rotated")
                        DispatchQueue.main.async {
                            self.lastRekey = Date()
                        }
                    }
                }
            } catch {
                QwaveLog.tunnel.error(
                    "Rekey negotiation failed; keeping current PSK: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard let message = String(data: messageData, encoding: .utf8) else {
            completionHandler?(nil)
            return
        }
        switch message {
        case "stats":
            adapter.getRuntimeConfiguration { configuration in
                completionHandler?(configuration.map { Data($0.utf8) })
            }
        default:
            completionHandler?(nil)
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
