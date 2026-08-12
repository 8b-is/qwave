import Foundation

/// Everything the packet-tunnel extension needs to bring up a WireGuard
/// session — except the private key, which stays in the shared keychain and
/// is resolved inside the extension. This struct round-trips through
/// `NETunnelProviderProtocol.providerConfiguration`.
public struct TunnelSessionConfig: Codable, Equatable, Sendable {
    /// In-tunnel addresses assigned by Mullvad, e.g. ["10.67.1.2/32", "fc00::.../128"].
    public var interfaceAddresses: [String]
    /// In-tunnel DNS (Mullvad gateway — also the ad/tracker-blocking resolver).
    public var dnsServers: [String]
    public var peerPublicKeyBase64: String
    /// "ip:port"
    public var peerEndpoint: String
    public var allowedIPs: [String]
    public var relayHostname: String
    /// Stage B: quantum-resistant PSK negotiation before handshake.
    public var quantumResistant: Bool

    public init(
        interfaceAddresses: [String],
        dnsServers: [String],
        peerPublicKeyBase64: String,
        peerEndpoint: String,
        allowedIPs: [String] = ["0.0.0.0/0", "::/0"],
        relayHostname: String,
        quantumResistant: Bool = false
    ) {
        self.interfaceAddresses = interfaceAddresses
        self.dnsServers = dnsServers
        self.peerPublicKeyBase64 = peerPublicKeyBase64
        self.peerEndpoint = peerEndpoint
        self.allowedIPs = allowedIPs
        self.relayHostname = relayHostname
        self.quantumResistant = quantumResistant
    }

    private static let configurationKey = "qwave.tunnelSessionConfig"

    public func providerConfiguration() throws -> [String: Any] {
        let data = try JSONEncoder().encode(self)
        return [Self.configurationKey: data]
    }

    public init?(providerConfiguration: [String: Any]?) {
        guard let data = providerConfiguration?[Self.configurationKey] as? Data,
              let decoded = try? JSONDecoder().decode(TunnelSessionConfig.self, from: data)
        else {
            return nil
        }
        self = decoded
    }

    /// Builds the session config for a chosen relay + registered device.
    public static func make(
        device: MullvadDevice,
        relayList: RelayList,
        selected: SelectedRelay,
        quantumResistant: Bool = false
    ) -> TunnelSessionConfig {
        TunnelSessionConfig(
            interfaceAddresses: [device.ipv4Address, device.ipv6Address],
            dnsServers: [relayList.wireguard.ipv4Gateway, relayList.wireguard.ipv6Gateway],
            peerPublicKeyBase64: selected.relay.publicKey,
            peerEndpoint: selected.endpoint,
            relayHostname: selected.relay.hostname,
            quantumResistant: quantumResistant
        )
    }
}
