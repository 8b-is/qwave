import Testing
import Foundation
@testable import PostQuantum

/// Negative/tamper KATs for the hybrid KEM boundary (v0.3.0 "Trust &
/// Distribution"): malformed and hostile inputs must fail *cleanly* —
/// thrown errors or implicit rejection, never a trap and never a silently
/// wrong shared secret accepted as valid. Uses the committed hybrid vectors
/// (fixed keys) so no slow McEliece keygen runs here.
struct HybridKEMNegativeSuite {
    struct Vector: Decodable, CustomTestStringConvertible {
        let name: String
        let seed: String
        let ek: String
        let dk: String
        let ct: String
        let ss: String
        var testDescription: String { name }
    }

    static let allVectors: [Vector] = {
        guard let url = Bundle.module.url(forResource: "hybrid_vectors", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let vectors = try? JSONDecoder().decode([Vector].self, from: data)
        else { return [] }
        return vectors
    }()

    @Test func fixturesArePresent() {
        #expect(!Self.allVectors.isEmpty)
    }

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

    @Test(arguments: allVectors)
    func decapsulateRejectsTruncatedKey(vector: Vector) {
        let dk = Data(hexVector: vector.dk)
        let ct = Data(hexVector: vector.ct)
        #expect(throws: HybridKEM.HybridKEMError.self) {
            _ = try HybridKEM.decapsulate(dk: dk.dropLast(1), ct: ct)
        }
        #expect(throws: HybridKEM.HybridKEMError.self) {
            _ = try HybridKEM.decapsulate(dk: Data(), ct: ct)
        }
    }

    @Test(arguments: allVectors)
    func decapsulateRejectsTruncatedCiphertext(vector: Vector) {
        let dk = Data(hexVector: vector.dk)
        let ct = Data(hexVector: vector.ct)
        #expect(throws: HybridKEM.HybridKEMError.self) {
            _ = try HybridKEM.decapsulate(dk: dk, ct: ct.dropLast(1))
        }
        #expect(throws: HybridKEM.HybridKEMError.self) {
            _ = try HybridKEM.decapsulate(dk: dk, ct: ct + Data([0]))
        }
    }

    // MARK: - Tampered ciphertexts

    /// A bit flip in the ML-KEM half triggers implicit rejection: decapsulate
    /// still succeeds but derives a DIFFERENT secret — deterministically —
    /// so the tunnel handshake fails instead of accepting attacker input.
    @Test(arguments: allVectors)
    func mlkemBitFlipChangesSharedSecret(vector: Vector) throws {
        let dk = Data(hexVector: vector.dk)
        var ct = Data(hexVector: vector.ct)
        ct[100] ^= 0x01

        let ss1 = try HybridKEM.decapsulate(dk: dk, ct: ct)
        let ss2 = try HybridKEM.decapsulate(dk: dk, ct: ct)
        #expect(ss1 != Data(hexVector: vector.ss), "tampered ct must not yield the honest secret")
        #expect(ss1 == ss2, "implicit rejection must be deterministic")
        #expect(ss1.count == HybridKEM.ssSize)
    }

    /// A bit flip in the McEliece half must throw (decoding failure) —
    /// the corrected word check catches it.
    @Test(arguments: allVectors)
    func mcelieceBitFlipThrows(vector: Vector) {
        let dk = Data(hexVector: vector.dk)
        var ct = Data(hexVector: vector.ct)
        ct[MLKEM768.ctSize + 10] ^= 0x01

        #expect(throws: (any Error).self) {
            _ = try HybridKEM.decapsulate(dk: dk, ct: ct)
        }
    }

    /// Sanity: the untampered vector still round-trips after the boundary
    /// change from preconditions to thrown errors.
    @Test(arguments: allVectors)
    func honestVectorStillDecapsulates(vector: Vector) throws {
        let ss = try HybridKEM.decapsulate(dk: Data(hexVector: vector.dk), ct: Data(hexVector: vector.ct))
        #expect(ss == Data(hexVector: vector.ss))
    }
}
