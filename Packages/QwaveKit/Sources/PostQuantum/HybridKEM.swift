import Foundation

/// Post-quantum leg of the tunnel PSK: ML-KEM-768 (lattice, FIPS 203).
///
/// "Hybrid" refers to the combination with the classical Curve25519 WireGuard
/// handshake — an attacker must break both ML-KEM-768 and Curve25519 to
/// recover the tunnel PSK. Domain separation via a hardcoded SHAKE256 label;
/// the PSK derivation mirrors the "hash the shared secret into the PSK" design
/// of Mullvad's quantum tunnels (docs/VPN_STAGE_B.md).
///
/// A second, code-based KEM leg (a construction named "ClassicMcEliece348864")
/// was removed in v0.6.0: it did not implement Classic McEliece and had no
/// conformance vectors, so it added review surface and key size without adding
/// any assurance. See CHANGELOG.md.
public enum HybridKEM {
    public static let ekSize = MLKEM768.ekSize
    public static let dkSize = MLKEM768.dkSize
    public static let ctSize = MLKEM768.ctSize
    public static let ssSize = 32

    /// Wrong-size inputs at this boundary throw instead of trapping: the
    /// callers run inside the packet tunnel provider, where a precondition
    /// failure kills the tunnel process.
    public enum HybridKEMError: Error, Equatable {
        case invalidInputSize(parameter: String, expected: Int, actual: Int)
    }

    private static func requireSize(_ data: Data, _ expected: Int, _ parameter: String) throws {
        guard data.count == expected else {
            throw HybridKEMError.invalidInputSize(parameter: parameter, expected: expected, actual: data.count)
        }
    }

    private static let pskLabel = Data("qwave/pq-psk/v1".utf8)
    private static let mlkemKgLabel = Data("qwave/mlkem-kg".utf8)
    private static let mlkemEncLabel = Data("qwave/mlkem-enc".utf8)

    /// seed: 32 bytes. Returns (ek, dk).
    public static func keygen(seed: Data) throws -> (ek: Data, dk: Data) {
        try requireSize(seed, 32, "seed")
        // ML-KEM needs two independent 32-byte seeds (d and z); expand the
        // caller's single seed into both.
        let seeds = Keccak.shake256(mlkemKgLabel + seed, count: 64)
        return MLKEM768.keygen(d: seeds.prefix(32), z: Data(seeds.dropFirst(32)))
    }

    /// seed: 32 bytes. Returns (ct, ss).
    public static func encapsulate(ek: Data, seed: Data) throws -> (ct: Data, ss: Data) {
        try requireSize(ek, ekSize, "ek")
        try requireSize(seed, 32, "seed")
        let m = Keccak.shake256(mlkemEncLabel + seed, count: 32)
        let (ct, ssMlkem) = try MLKEM768.encaps(ek: Data(ek), m: m)
        return (ct, Keccak.shake256(pskLabel + ssMlkem, count: 32))
    }

    /// Returns the 32-byte shared secret, or throws when the input sizes are
    /// wrong. A tampered ciphertext is not an error: ML-KEM's implicit
    /// rejection returns a different secret, and the handshake fails there.
    public static func decapsulate(dk: Data, ct: Data) throws -> Data {
        try requireSize(dk, dkSize, "dk")
        try requireSize(ct, ctSize, "ct")
        let ssMlkem = MLKEM768.decaps(dk: Data(dk), ct: Data(ct))
        return Keccak.shake256(pskLabel + ssMlkem, count: 32)
    }
}
