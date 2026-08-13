import XCTest
@testable import PostQuantum

/// Known-answer + property tests for Classic McEliece 348864.
///
/// Vectors were produced by an independent Python implementation (schoolbook
/// GF arithmetic, batch inversion, Patterson decoding) that round-trips
/// internally; the Swift implementation must reproduce them exactly.
final class ClassicMcEliece348864Tests: XCTestCase {
    private struct Vector: Decodable {
        let name: String
        let seed: String
        let ek: String
        let dk: String
        let msg: String
        let errors: [Int]
        let ct: String
        let ss: String
    }

    private var vectors: [Vector] = []

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "mceliece348864_vectors", withExtension: "json"))
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
            let (ek, dk) = try ClassicMcEliece348864.keygen(seed: unhex(v.seed))
            XCTAssertEqual(ek, unhex(v.ek), "\(v.name) ek mismatch")
            XCTAssertEqual(dk, unhex(v.dk), "\(v.name) dk mismatch")
        }
    }

    func testEncapsMatchesVectors() throws {
        for v in vectors {
            let (ct, ss) = try ClassicMcEliece348864.encapsulate(ek: unhex(v.ek), seed: unhex(v.seed))
            XCTAssertEqual(ct, unhex(v.ct), "\(v.name) ct mismatch")
            XCTAssertEqual(ss, unhex(v.ss), "\(v.name) ss mismatch")
        }
    }

    func testDecapsMatchesVectors() throws {
        for v in vectors {
            let ss = try ClassicMcEliece348864.decapsulate(dk: unhex(v.dk), ct: unhex(v.ct))
            XCTAssertEqual(ss, unhex(v.ss), "\(v.name) decaps mismatch")
        }
    }

    // MARK: - Behavioural tests

    func testKeygenIsDeterministic() throws {
        let seed = Data(repeating: 0x77, count: 32)
        let (ek1, dk1) = try ClassicMcEliece348864.keygen(seed: seed)
        let (ek2, dk2) = try ClassicMcEliece348864.keygen(seed: seed)
        XCTAssertEqual(ek1, ek2)
        XCTAssertEqual(dk1, dk2)
    }

    func testFullFlowRoundTrip() throws {
        let seed = Data((0..<32).map { UInt8(($0 * 3 + 11) % 251) })
        let (ek, dk) = try ClassicMcEliece348864.keygen(seed: seed)
        let (ct, ss) = try ClassicMcEliece348864.encapsulate(ek: ek, seed: seed)
        XCTAssertEqual(ct.count, ClassicMcEliece348864.ctSize)
        XCTAssertEqual(ss.count, 32)
        let ss2 = try ClassicMcEliece348864.decapsulate(dk: dk, ct: ct)
        XCTAssertEqual(ss2, ss)
    }

    func testTamperedCiphertextThrows() throws {
        let seed = Data(repeating: 0x5A, count: 32)
        let (ek, dk) = try ClassicMcEliece348864.keygen(seed: seed)
        let (ct, _) = try ClassicMcEliece348864.encapsulate(ek: ek, seed: seed)
        // flip one bit in the ciphertext: decoding must fail the codeword check
        var tampered = ct
        tampered[100] ^= 0x01
        XCTAssertThrowsError(try ClassicMcEliece348864.decapsulate(dk: dk, ct: tampered))
    }

    func testGFArithmetic() throws {
        // multiplicative identity and inverses
        for _ in 0..<64 {
            let a = UInt16.random(in: 1...0xFFF)
            XCTAssertEqual(ClassicMcEliece348864.gfMul(a, 1), a)
            let inv = try ClassicMcEliece348864.gfInverse(a)
            XCTAssertEqual(ClassicMcEliece348864.gfMul(a, inv), 1)
        }
        // distributivity spot-check
        let a = UInt16(0x2A3), b = UInt16(0x1B7), c = UInt16(0x0C5)
        XCTAssertEqual(
            ClassicMcEliece348864.gfMul(a, ClassicMcEliece348864.gfMul(b, c)),
            ClassicMcEliece348864.gfMul(ClassicMcEliece348864.gfMul(a, b), c)
        )
        // Fermat: a^(2^12 - 1) == 1 for all nonzero a (spot-check)
        var acc: UInt16 = 1
        for _ in 0..<4095 {
            acc = ClassicMcEliece348864.gfMul(acc, a)
        }
        XCTAssertEqual(acc, 1)
    }

    func testPolynomialEuclid() throws {
        // (x + L) * (x + L)^-1 == 1 mod g for a random squarefree g
        let seed = Data(repeating: 0x11, count: 32)
        let (_, dk) = try ClassicMcEliece348864.keygen(seed: seed)
        let g = ClassicMcEliece348864.unpackFieldElements(dk.prefix(98), count: 65)
        let support = ClassicMcEliece348864.unpackFieldElements(
            dk.subdata(in: 98..<dk.count), count: ClassicMcEliece348864.n)
        for j in [0, 17, 999, 3487] {
            let factor = [support[j], UInt16(1)]
            let inverse = try ClassicMcEliece348864.polyInverse(factor, mod: g)
            let product = try ClassicMcEliece348864.polyMod(ClassicMcEliece348864.polyMul(factor, inverse), g)
            XCTAssertEqual(product, [1])
        }
    }
}
