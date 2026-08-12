import Foundation

/// Material produced by the (quantum-resistant) ephemeral peer exchange.
public struct PresharedKeyMaterial: Equatable, Sendable {
    /// 32-byte WireGuard preshared key to install on the peer.
    public let presharedKey: Data
    /// Replacement ephemeral private key, when the exchange rotates it.
    public let ephemeralPrivateKey: Data?

    public init(presharedKey: Data, ephemeralPrivateKey: Data? = nil) {
        self.presharedKey = presharedKey
        self.ephemeralPrivateKey = ephemeralPrivateKey
    }
}

/// **The Stage B seam.**
///
/// Mullvad's quantum-resistant tunnels derive a WireGuard preshared key via
/// an in-tunnel exchange with the relay (ML-KEM + Classic McEliece — see
/// docs/VPN_STAGE_B.md). That negotiation necessarily runs *inside* the
/// packet tunnel provider, after a classic handshake, against the relay's
/// in-tunnel service; the tunnel is then rekeyed with the derived PSK.
///
/// Stage A ships `NoopEphemeralPeerNegotiator` (classic WireGuard, no PSK).
/// Stage B implements this protocol; `PacketTunnelProvider` already calls it,
/// so no call sites change.
public protocol EphemeralPeerNegotiating: Sendable {
    /// Returns nil when no PSK should be installed (classic WireGuard).
    func negotiatePresharedKey(config: TunnelSessionConfig) async throws -> PresharedKeyMaterial?
}

public struct NoopEphemeralPeerNegotiator: EphemeralPeerNegotiating {
    public init() {}

    public func negotiatePresharedKey(config: TunnelSessionConfig) async throws -> PresharedKeyMaterial? {
        nil
    }
}
