import Testing
import Foundation
@testable import PostQuantum

/// Negative/tamper KATs for the KEM boundary (v0.3.0 "Trust & Distribution"):
/// malformed and hostile inputs must fail *cleanly* — thrown errors or
/// implicit rejection, never a trap and never a silently wrong shared secret
/// accepted as valid.
///
/// Keys are generated inline. That used to be too slow (Classic McEliece
/// keygen dominated the suite, hence the committed fixtures); with the
/// code-based leg gone, ML-KEM-768 keygen is milliseconds.
struct HybridKEMNegativeSuite {
    static let seed = Data(repeating: 0x5C, count: 32)

    static let keys: (ek: Data, dk: Data) = {
        // swiftlint:disable:next force_try
        try! HybridKEM.keygen(seed: seed)
    }()

    static let honest: (ct: Data, ss: Data) = {
        // swiftlint:disable:next force_try
        try! HybridKEM.encapsulate(ek: keys.ek, seed: seed)
    }()

    // MARK: - Wrong-size inputs fail cleanly (no traps)

    @Test func keygenRejectsWrongSeedSize() {
        #expect(throws: HybridKEM.HybridKEMError.invalidInputSize(parameter: "seed", expected: 32, actual: 31)) {
            _ = try HybridKEM.keygen(seed: Data(repeating: 0, count: 31))
        }
    }

    @Test(arguments: [0, 1, HybridKEM.ekSize - 1, HybridKEM.ekSize + 1])
    func encapsulateRejectsWrongEKSize(size: Int) {
        #expect(throws: HybridKEM.HybridKEMError.self) {
            _ = try HybridKEM.encapsulate(ek: Data(repeating: 0, count: size), seed: Data(repeating: 0, count: 32))
        }
    }

    /// A right-*size* key whose coefficients are not reduced mod q: FIPS 203
    /// §7.2's modulus check is what stops it, not the size check.
    ///
    /// Note what this does NOT cover: §7.2 is only a type check plus a modulus
    /// check, so an all-zero `ek` — every coefficient 0, which is reduced —
    /// *passes* validation. Rejecting semantically useless-but-well-formed keys
    /// is not part of the standard's input check.
    @Test func encapsulateRejectsUnreducedEK() {
        // Start from a valid key and force one coefficient out of range.
        var ek = Self.keys.ek
        // 0xFFF is >= q in every 12-bit slot, so this fails the modulus check.
        ek[0] = 0xFF
        ek[1] |= 0x0F
        #expect(throws: MLKEM768.MLKEMError.invalidEncapsulationKey) {
            _ = try HybridKEM.encapsulate(ek: ek, seed: Data(repeating: 0, count: 32))
        }
    }

    @Test func decapsulateRejectsTruncatedKey() {
        #expect(throws: HybridKEM.HybridKEMError.self) {
            _ = try HybridKEM.decapsulate(dk: Self.keys.dk.dropLast(1), ct: Self.honest.ct)
        }
        #expect(throws: HybridKEM.HybridKEMError.self) {
            _ = try HybridKEM.decapsulate(dk: Data(), ct: Self.honest.ct)
        }
    }

    @Test func decapsulateRejectsTruncatedCiphertext() {
        #expect(throws: HybridKEM.HybridKEMError.self) {
            _ = try HybridKEM.decapsulate(dk: Self.keys.dk, ct: Self.honest.ct.dropLast(1))
        }
        #expect(throws: HybridKEM.HybridKEMError.self) {
            _ = try HybridKEM.decapsulate(dk: Self.keys.dk, ct: Self.honest.ct + Data([0]))
        }
    }

    // MARK: - Tampered ciphertexts

    /// A bit flip triggers implicit rejection: decapsulate still succeeds but
    /// derives a DIFFERENT secret — deterministically — so the tunnel
    /// handshake fails instead of accepting attacker input.
    @Test(arguments: [0, 100, 700, HybridKEM.ctSize - 1])
    func bitFlipChangesSharedSecret(index: Int) throws {
        var ct = Self.honest.ct
        ct[index] ^= 0x01

        let ss1 = try HybridKEM.decapsulate(dk: Self.keys.dk, ct: ct)
        let ss2 = try HybridKEM.decapsulate(dk: Self.keys.dk, ct: ct)
        #expect(ss1 != Self.honest.ss, "tampered ct must not yield the honest secret")
        #expect(ss1 == ss2, "implicit rejection must be deterministic")
        #expect(ss1.count == HybridKEM.ssSize)
    }

    @Test func honestCiphertextStillDecapsulates() throws {
        let ss = try HybridKEM.decapsulate(dk: Self.keys.dk, ct: Self.honest.ct)
        #expect(ss == Self.honest.ss)
    }
}
