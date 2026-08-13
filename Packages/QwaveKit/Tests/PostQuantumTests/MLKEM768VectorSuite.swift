import Testing
import Foundation
@testable import PostQuantum

/// Swift Testing port of the ML-KEM-768 KAT loops: one test case per vector,
/// so a mismatch reports the failing vector by name and the remaining
/// vectors still run.
struct MLKEM768VectorSuite {
    struct Vector: Decodable, CustomTestStringConvertible {
        let name: String
        let d: String
        let ek: String
        let dk: String
        let m: String
        let ct: String
        let ss: String
        var testDescription: String { name }
    }

    static let allVectors: [Vector] = {
        guard let url = Bundle.module.url(forResource: "mlkem_vectors", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let vectors = try? JSONDecoder().decode([Vector].self, from: data)
        else { return [] }
        return vectors
    }()

    @Test func fixturesArePresent() {
        #expect(!Self.allVectors.isEmpty)
    }

    @Test(arguments: allVectors)
    func keygen(vector: Vector) {
        let (ek, dk) = MLKEM768.keygen(seed: Data(hexVector: vector.d))
        #expect(ek == Data(hexVector: vector.ek))
        #expect(dk == Data(hexVector: vector.dk))
    }

    @Test(arguments: allVectors)
    func encaps(vector: Vector) {
        let (ct, ss) = MLKEM768.encaps(ek: Data(hexVector: vector.ek), m: Data(hexVector: vector.m))
        #expect(ct == Data(hexVector: vector.ct))
        #expect(ss == Data(hexVector: vector.ss))
    }

    @Test(arguments: allVectors)
    func decaps(vector: Vector) {
        let ss = MLKEM768.decaps(dk: Data(hexVector: vector.dk), ct: Data(hexVector: vector.ct))
        #expect(ss == Data(hexVector: vector.ss))
    }
}

/// Classic McEliece 348864 vector loops, keygen excluded on purpose: keygen
/// dominates the suite's runtime (large-matrix RREF), and the XCTest KATs
/// already pin it. Encaps/decaps run against the fixed keys in the vectors.
struct McEliece348864VectorSuite {
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
        guard let url = Bundle.module.url(forResource: "mceliece348864_vectors", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let vectors = try? JSONDecoder().decode([Vector].self, from: data)
        else { return [] }
        return vectors
    }()

    @Test func fixturesArePresent() {
        #expect(!Self.allVectors.isEmpty)
    }

    @Test(arguments: allVectors)
    func encaps(vector: Vector) throws {
        let (ct, ss) = try ClassicMcEliece348864.encapsulate(
            ek: Data(hexVector: vector.ek),
            seed: Data(hexVector: vector.seed)
        )
        #expect(ct == Data(hexVector: vector.ct))
        #expect(ss == Data(hexVector: vector.ss))
    }

    @Test(arguments: allVectors)
    func decaps(vector: Vector) throws {
        let ss = try ClassicMcEliece348864.decapsulate(
            dk: Data(hexVector: vector.dk),
            ct: Data(hexVector: vector.ct)
        )
        #expect(ss == Data(hexVector: vector.ss))
    }
}

extension Data {
    /// Strict hex decoding for fixture strings (fixtures are trusted input;
    /// malformed hex is a broken fixture and should trap loudly).
    init(hexVector hex: String) {
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self = data
    }
}
