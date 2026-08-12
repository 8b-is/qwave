import Foundation
import NetworkExtension
import WireGuardKit
import VPNKit
import QwaveSupport

enum PacketTunnelError: Error {
    case missingConfiguration
    case missingPrivateKey
    case invalidConfiguration(String)
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

    private let negotiator: EphemeralPeerNegotiating = NoopEphemeralPeerNegotiator()
    private let secrets = KeychainSecretStore()

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

        Task {
            do {
                var tunnelConfiguration = try Self.makeTunnelConfiguration(
                    sessionConfig: sessionConfig,
                    privateKey: privateKey
                )

                // Stage B seam: quantum-resistant preshared key negotiation.
                if sessionConfig.quantumResistant,
                   let material = try? await self.negotiator.negotiatePresharedKey(config: sessionConfig),
                   let peer = tunnelConfiguration.peers.first {
                    var pskPeer = peer
                    pskPeer.preSharedKey = PreSharedKey(rawValue: material.presharedKey)
                    tunnelConfiguration = TunnelConfiguration(
                        name: tunnelConfiguration.name,
                        interface: tunnelConfiguration.interface,
                        peers: [pskPeer]
                    )
                }

                let configuration = tunnelConfiguration
                self.adapter.start(tunnelConfiguration: configuration) { error in
                    if let error {
                        QwaveLog.tunnel.error("Adapter start failed: \(error.localizedDescription, privacy: .public)")
                    } else {
                        QwaveLog.tunnel.info("Tunnel up via \(sessionConfig.relayHostname, privacy: .public)")
                    }
                    completionHandler(error)
                }
            } catch {
                completionHandler(error)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        adapter.stop { error in
            if let error {
                QwaveLog.tunnel.error("Adapter stop failed: \(error.localizedDescription, privacy: .public)")
            }
            completionHandler()
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
