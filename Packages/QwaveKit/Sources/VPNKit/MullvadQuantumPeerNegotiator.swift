import Foundation
import PostQuantum
import QwaveSupport

/// **Stage B: the post-quantum ephemeral peer negotiator.**
///
/// Implements `EphemeralPeerNegotiating` with the real hybrid KEM
/// (ML-KEM-768 + Classic McEliece 348864, `PostQuantum.HybridKEM`):
///
/// 1. Generate a hybrid key pair for this session (fresh per connection).
/// 2. Ask the relay's in-tunnel ephemeral-peer service (via the transport)
///    to encapsulate against our public half.
/// 3. Decapsulate both legs and mix the shared secrets into the tunnel PSK.
///
/// The derived PSK is installed on the WireGuard peer by
/// `PacketTunnelProvider`, which already calls this seam; on any failure the
/// caller falls back to classic WireGuard (no PSK), preserving the
/// availability guarantees of Stage A.
public struct MullvadQuantumPeerNegotiator: EphemeralPeerNegotiating {
    private let transport: QuantumTransporting
    private let seed: Data?

    public init(transport: QuantumTransporting? = nil, seed: Data? = nil) {
        self.transport = transport ?? MullvadEphemeralPeerTransport()
        self.seed = seed
    }

    public func negotiatePresharedKey(config: TunnelSessionConfig) async throws -> PresharedKeyMaterial? {
        guard config.quantumResistant else {
            QwaveLog.vpn.debug("Quantum resistance disabled; classic WireGuard")
            return nil
        }

        // Session entropy; injectable for deterministic tests.
        let sessionSeed = seed ?? Self.randomSeed()

        let (ek, dk) = try HybridKEM.keygen(seed: sessionSeed)
        let request = EphemeralPeerRequest(
            wgPublicKey: config.peerPublicKeyBase64,
            mlkemPublicKey: ek.prefix(MLKEM768.ekSize).base64EncodedString(),
            mceliecePublicKey: ek.dropFirst(MLKEM768.ekSize).base64EncodedString(),
            relayHostname: config.relayHostname
        )
        let response = try await transport.requestEphemeralPeer(request)
        guard let ciphertext = Data(base64Encoded: response.ciphertextBundle),
              ciphertext.count == HybridKEM.ctSize
        else {
            throw QuantumTransportError.invalidResponse
        }

        let psk = try HybridKEM.decapsulate(dk: dk, ct: ciphertext)
        QwaveLog.vpn.info("Quantum-resistant PSK established for \(config.relayHostname, privacy: .public)")
        return PresharedKeyMaterial(presharedKey: psk)
    }

    private static func randomSeed() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        // SecRandomCopyBytes keeps the KEM seed out of userland RNG state.
        _ = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
        }
        return Data(bytes)
    }
}
