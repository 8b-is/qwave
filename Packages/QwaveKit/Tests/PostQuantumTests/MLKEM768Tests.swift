import XCTest
@testable import PostQuantum

/// Known-answer + property tests for FIPS 203 ML-KEM-768.
///
/// The KAT vectors were produced by an independent Python implementation
/// (schoolbook arithmetic, no NTT) that round-trips internally; the Swift
/// NTT-based implementation must reproduce them exactly.
final class MLKEM768Tests: XCTestCase {
    private struct Vector: Decodable {
        let name: String
        let d: String
        let ek: String
        let dk: String
        let m: String
        let ct: String
        let ss: String
    }

    private var vectors: [Vector] = []

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "mlkem_vectors", withExtension: "json"))
        let data = try Data(contentsOf: url)
        vectors = try JSONDecoder().decode([Vector].self, from: data)
    }

    private func unhex(_ s: String) -> Data {
        var data = Data()
        var index = s.startIndex
        while index < s.endIndex {
            let next = s.index(index, offsetBy: 2)
            data.append(UInt8(s[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    // MARK: - Known-answer tests

    func testKeygenMatchesVectors() throws {
        for v in vectors {
            let (ek, dk) = MLKEM768.keygen(seed: unhex(v.d))
            XCTAssertEqual(ek, unhex(v.ek), "\(v.name) ek mismatch")
            XCTAssertEqual(dk, unhex(v.dk), "\(v.name) dk mismatch")
        }
    }

    func testEncapsMatchesVectors() throws {
        for v in vectors {
            let (ct, ss) = MLKEM768.encaps(ek: unhex(v.ek), m: unhex(v.m))
            XCTAssertEqual(ct, unhex(v.ct), "\(v.name) ct mismatch")
            XCTAssertEqual(ss, unhex(v.ss), "\(v.name) ss mismatch")
        }
    }

    func testDecapsMatchesVectors() throws {
        for v in vectors {
            let ss = MLKEM768.decaps(dk: unhex(v.dk), ct: unhex(v.ct))
            XCTAssertEqual(ss, unhex(v.ss), "\(v.name) decaps mismatch")
        }
    }

    // MARK: - Behavioural tests

    func testFullFlowRoundTrip() throws {
        let d = Data((0..<32).map { UInt8(($0 * 7) % 251) })
        let m = Data((0..<32).map { UInt8(($0 * 13) % 251) })
        let (ek, dk) = MLKEM768.keygen(seed: d)
        let (ct, ss) = MLKEM768.encaps(ek: ek, m: m)
        XCTAssertEqual(MLKEM768.decaps(dk: dk, ct: ct), ss)
    }

    func testImplicitRejectionOnTamperedCiphertext() throws {
        let (ek, dk) = MLKEM768.keygen(seed: Data(repeating: 0x5A, count: 32))
        let (ct, ss) = MLKEM768.encaps(ek: ek, m: Data(repeating: 0x0F, count: 32))
        var tampered = ct
        tampered[tampered.count - 1] ^= 0x01
        XCTAssertNotEqual(tampered, ct)
        XCTAssertNotEqual(MLKEM768.decaps(dk: dk, ct: tampered), ss)
        // deterministic under the same bad ciphertext (z-based rejection)
        XCTAssertEqual(MLKEM768.decaps(dk: dk, ct: tampered), MLKEM768.decaps(dk: dk, ct: tampered))
    }

    // MARK: - NTT algebra (the load-bearing arithmetic)

    private func randomPoly(seed: UInt64) -> [Int] {
        var s = seed
        return (0..<256).map { _ in
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Int(s % UInt64(MLKEM768.q))
        }
    }

    private func schoolbookMul(_ a: [Int], _ b: [Int]) -> [Int] {
        var acc = [Int](repeating: 0, count: 512)
        for i in 0..<256 {
            for j in 0..<256 {
                acc[i + j] = (acc[i + j] + a[i] * b[j]) % MLKEM768.q
            }
        }
        return (0..<256).map { ((acc[$0] - acc[$0 + 256]) % MLKEM768.q + MLKEM768.q) % MLKEM768.q }
    }

    func testNTTIsInvertible() {
        for seed in 0..<8 {
            let f = randomPoly(seed: UInt64(seed))
            let round = MLKEM768.intt(MLKEM768.ntt(f))
            XCTAssertEqual(round, f, "ntt∘intt ≠ id for seed \(seed)")
        }
    }

    func testNTTIsMultiplicative() {
        for seed in 0..<8 {
            let a = randomPoly(seed: UInt64(seed))
            let b = randomPoly(seed: UInt64(seed) &+ 1)
            // NTT of the schoolbook product == basemul of the NTTs (FIPS 203 "∘")
            let expected = MLKEM768.ntt(schoolbookMul(a, b))
            let actual = MLKEM768.basemul(MLKEM768.ntt(a), MLKEM768.ntt(b))
            XCTAssertEqual(actual, expected, "NTT homomorphism failed for seed \(seed)")
        }
    }

    func testZetaTableConsistency() {
        // zetas[i] = 17^BitRev7(i) mod q; verify against the definition.
        for i in 0..<128 {
            let expected = powmod(17, bitRev7(i), MLKEM768.q)
            XCTAssertEqual(MLKEM768.zetas[i], expected)
        }
    }

    private func powmod(_ base: Int, _ exp: Int, _ mod: Int) -> Int {
        var result = 1
        var b = base % mod
        var e = exp
        while e > 0 {
            if e & 1 == 1 { result = (result * b) % mod }
            b = (b * b) % mod
            e >>= 1
        }
        return result
    }

    private func bitRev7(_ i: Int) -> Int {
        var x = i
        var r = 0
        for _ in 0..<7 {
            r = (r << 1) | (x & 1)
            x >>= 1
        }
        return r
    }
}
