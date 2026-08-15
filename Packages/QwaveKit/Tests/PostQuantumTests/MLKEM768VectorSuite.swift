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
/// This is the only conformance evidence in the suite. The self-generated
/// round-trip fixtures that used to live here were removed: they proved
/// self-consistency and nothing else, and they went stale the moment the
/// implementation was corrected.
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
        let (ek, dk) = MLKEM768.keygen(d: Data(hexVector: vector.d), z: Data(hexVector: vector.z))
        #expect(ek == Data(hexVector: vector.ek))
        #expect(dk == Data(hexVector: vector.dk))
    }

    @Test(arguments: encapVectors)
    func encapsulation(vector: EncapVector) throws {
        let (ct, ss) = try MLKEM768.encaps(ek: Data(hexVector: vector.ek), m: Data(hexVector: vector.m))
        #expect(ct == Data(hexVector: vector.c))
        #expect(ss == Data(hexVector: vector.k))
    }

    /// Covers both "valid decapsulation" and "modified ciphertext" cases: for
    /// the latter the official `k` is the implicit-rejection secret J(z ‖ c),
    /// so a passing run proves the rejection path is conformant too.
    @Test(arguments: decapVectors)
    func decapsulation(vector: DecapVector) {
        let ss = MLKEM768.decaps(dk: Data(hexVector: vector.dk), ct: Data(hexVector: vector.c))
        #expect(ss == Data(hexVector: vector.k))
    }

    /// FIPS 203 §7.2 encapsulation-key input check (ACVP
    /// "encapsulationKeyCheck"): keys whose 12-bit coefficients are not
    /// reduced mod q must be rejected, not silently used.
    @Test(arguments: ekCheckVectors)
    func encapsulationKeyCheck(vector: EKCheckVector) {
        let ek = Data(hexVector: vector.ek)
        #expect(MLKEM768.validateEncapsulationKey(ek) == vector.valid, "reason: \(vector.reason)")
        if !vector.valid {
            #expect(throws: MLKEM768.MLKEMError.invalidEncapsulationKey) {
                _ = try MLKEM768.encaps(ek: ek, m: Data(repeating: 0, count: 32))
            }
        }
    }

    /// Property test — deliberately NOT a known-answer test.
    ///
    /// The rho below is the C2SP/CCTV "unluckysample" seed for ML-KEM-768: it
    /// needs 384 twelve-bit draws (576 XOF bytes, four SHAKE128 blocks) before
    /// SampleNTT accepts 256 coefficients, versus the 256..~280 draws a typical
    /// seed needs. The CCTV file's own ek/dk/c are FIPS 203 *ipd*-era (its rho
    /// is SHA3-512(d) rather than G(d ‖ k)), so they are not usable as an
    /// oracle — see the ATTRIBUTION file. Only the unlucky rho is reused, and
    /// only to prove the streaming XOF refills instead of truncating.
    @Test func unluckyRhoNeedsMoreThanOneSqueeze() {
        let rho = Data(hexVector: "5c3c6fe50d06fc1bbbffafc56ab7050f2773ee8ef8d28ca4b97b43c8d7202e71")
        let a = MLKEM768.sampleNTT(rho, 0, 0)
        #expect(a.count == 256)
        #expect(a.allSatisfy { $0 >= 0 && $0 < MLKEM768.q })
        // A single 384-byte squeeze can only ever yield 256 draws; this seed
        // needs 384, so a truncating implementation must disagree here.
        let truncated = MLKEM768.byteDecode12(Keccak.shake128(rho + Data([0, 0]), count: 384))
        #expect(a != truncated)
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
