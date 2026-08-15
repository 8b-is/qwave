import Testing
import Foundation
@testable import PostQuantum

/// **Conformance oracle: official NIST ACVP ML-KEM-768 vectors (FIPS 203).**
///
/// These are READ-ONLY TRUTH, copied verbatim from usnistgov/ACVP-Server —
/// see `Fixtures/mlkem768_acvp_vectors-ATTRIBUTION.txt` for source commits.
/// A failure here means *this implementation* is wrong. Never edit,
/// regenerate, filter to the passing subset, or delete a failing case.
///
/// This is the only conformance evidence in the suite. `MLKEM768VectorSuite`
/// below runs self-generated round-trip fixtures, which prove self-consistency
/// and nothing else.
struct MLKEM768ACVPSuite {
    struct KeyGenVector: Decodable, CustomTestStringConvertible {
        let name: String
        let d: String
        let z: String
        let ek: String
        let dk: String
        var testDescription: String { name }
    }

    struct EncapVector: Decodable, CustomTestStringConvertible {
        let name: String
        let ek: String
        let m: String
        let c: String
        let k: String
        var testDescription: String { name }
    }

    struct DecapVector: Decodable, CustomTestStringConvertible {
        let name: String
        let reason: String
        let dk: String
        let c: String
        let k: String
        var testDescription: String { name }
    }

    struct EKCheckVector: Decodable, CustomTestStringConvertible {
        let name: String
        let reason: String
        let ek: String
        let valid: Bool
        var testDescription: String { name }
    }

    struct Fixture: Decodable {
        let keyGen: [KeyGenVector]
        let encapsulation: [EncapVector]
        let decapsulation: [DecapVector]
        let encapsulationKeyCheck: [EKCheckVector]
    }

    static let fixture: Fixture = {
        guard let url = Bundle.module.url(forResource: "mlkem768_acvp_vectors", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let fixture = try? JSONDecoder().decode(Fixture.self, from: data)
        else {
            return Fixture(keyGen: [], encapsulation: [], decapsulation: [], encapsulationKeyCheck: [])
        }
        return fixture
    }()

    static let keyGenVectors = fixture.keyGen
    static let encapVectors = fixture.encapsulation
    static let decapVectors = fixture.decapsulation
    static let ekCheckVectors = fixture.encapsulationKeyCheck

    /// Guards against a silently-empty fixture turning the whole conformance
    /// suite into a no-op.
    @Test func officialVectorsAreLoaded() {
        #expect(Self.keyGenVectors.count == 7)
        #expect(Self.encapVectors.count == 8)
        #expect(Self.decapVectors.count == 6)
        #expect(Self.ekCheckVectors.count == 8)
    }

    @Test(arguments: keyGenVectors)
    func keyGen(vector: KeyGenVector) {
        let (ek, dk) = MLKEM768.keygen(seed: Data(hexVector: vector.d))
        #expect(ek == Data(hexVector: vector.ek))
        #expect(dk == Data(hexVector: vector.dk))
    }

    @Test(arguments: encapVectors)
    func encapsulation(vector: EncapVector) {
        let (ct, ss) = MLKEM768.encaps(ek: Data(hexVector: vector.ek), m: Data(hexVector: vector.m))
        #expect(ct == Data(hexVector: vector.c))
        #expect(ss == Data(hexVector: vector.k))
    }

    @Test(arguments: decapVectors)
    func decapsulation(vector: DecapVector) {
        let ss = MLKEM768.decaps(dk: Data(hexVector: vector.dk), ct: Data(hexVector: vector.c))
        #expect(ss == Data(hexVector: vector.k))
    }
}

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
