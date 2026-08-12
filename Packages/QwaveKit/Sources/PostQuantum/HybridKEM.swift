import Foundation

/// Dual-KEM hybrid: ML-KEM-768 (lattice, FIPS 203) + Classic McEliece 348864
/// (code-based). The shared secret mixes both legs — an attacker must break
/// both (and Curve25519, via the WireGuard handshake) to recover the tunnel
/// PSK. Domain separation via hardcoded SHAKE256 labels; the PSK derivation
/// mirrors the "hash both shared secrets" design of Mullvad's quantum tunnels
/// (docs/VPN_STAGE_B.md).
public enum HybridKEM {
    public static let ekSize = MLKEM768.ekSize + ClassicMcEliece348864.ekSize
    public static let dkSize = MLKEM768.dkSize + ClassicMcEliece348864.dkSize
    public static let ctSize = MLKEM768.ctSize + ClassicMcEliece348864.ctSize
    public static let ssSize = 32

    private static let pskLabel = Data("qwave/pq-psk/v1".utf8)
    private static let mlkemKgLabel = Data("qwave/mlkem-kg".utf8)
    private static let mlkemEncLabel = Data("qwave/mlkem-enc".utf8)
    private static let mceKgLabel = Data("qwave/mceliece-kg".utf8)
    private static let mceEncLabel = Data("qwave/mceliece-enc".utf8)

    /// seed: 32 bytes. Returns (ek, dk).
    public static func keygen(seed: Data) throws -> (ek: Data, dk: Data) {
        precondition(seed.count == 32)
        let (mlkemEk, mlkemDk) = MLKEM768.keygen(seed: Keccak.shake256(mlkemKgLabel + seed, count: 32))
        let (mceEk, mceDk) = try ClassicMcEliece348864.keygen(seed: Keccak.shake256(mceKgLabel + seed, count: 32))
        return (mlkemEk + mceEk, mlkemDk + mceDk)
    }

    /// seed: 32 bytes. Returns (ct, ss).
    public static func encapsulate(ek: Data, seed: Data) throws -> (ct: Data, ss: Data) {
        precondition(ek.count == ekSize && seed.count == 32)
        let mlkemEk = ek.prefix(MLKEM768.ekSize)
        let mceEk = ek.subdata(in: MLKEM768.ekSize..<ek.count)

        let mlkemSeed = Keccak.shake256(mlkemEncLabel + seed, count: 32)
        let (ctMlkem, ssMlkem) = MLKEM768.encaps(ek: mlkemEk, m: mlkemSeed)

        let mceSeed = Keccak.shake256(mceEncLabel + seed, count: 32)
        let (ctMce, ssMce) = try ClassicMcEliece348864.encapsulate(ek: mceEk, seed: mceSeed)

        let ct = ctMlkem + ctMce
        let ss = Keccak.shake256(pskLabel + ssMlkem + ssMce, count: 32)
        return (ct, ss)
    }

    /// Returns the 32-byte shared secret, or throws when either leg fails.
    public static func decapsulate(dk: Data, ct: Data) throws -> Data {
        precondition(dk.count == dkSize && ct.count == ctSize)
        let mlkemDk = dk.prefix(MLKEM768.dkSize)
        let mceDk = dk.subdata(in: MLKEM768.dkSize..<dk.count)
        let ctMlkem = ct.prefix(MLKEM768.ctSize)
        let ctMce = ct.subdata(in: MLKEM768.ctSize..<ct.count)

        let ssMlkem = MLKEM768.decaps(dk: mlkemDk, ct: ctMlkem)
        let ssMce = try ClassicMcEliece348864.decapsulate(dk: mceDk, ct: ctMce)
        return Keccak.shake256(pskLabel + ssMlkem + ssMce, count: 32)
    }
}
