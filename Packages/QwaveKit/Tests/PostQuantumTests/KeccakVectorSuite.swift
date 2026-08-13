import Testing
import Foundation
@testable import PostQuantum

/// Swift Testing port of the FIPS 202 KATs: each named fixture vector is its
/// own test case. The table mirrors the fixture keys in
/// `keccak_vectors.json` one-to-one.
struct KeccakVectorSuite {
    enum Algo: Sendable {
        case sha3_224, sha3_256, sha3_384, sha3_512
        case shake128(count: Int)
        case shake256(count: Int)

        func compute(_ input: Data) -> Data {
            switch self {
            case .sha3_224: return Keccak.sha3_224(input)
            case .sha3_256: return Keccak.sha3_256(input)
            case .sha3_384: return Keccak.sha3_384(input)
            case .sha3_512: return Keccak.sha3_512(input)
            case .shake128(let count): return Keccak.shake128(input, count: count)
            case .shake256(let count): return Keccak.shake256(input, count: count)
            }
        }
    }

    struct Case: Sendable, CustomTestStringConvertible {
        let key: String
        let input: Data
        let algo: Algo
        var testDescription: String { key }
    }

    static let allCases: [Case] = [
        Case(key: "sha3_256_empty", input: Data(), algo: .sha3_256),
        Case(key: "sha3_256_abc", input: Data("abc".utf8), algo: .sha3_256),
        Case(key: "sha3_256_2blocks", input: Data(repeating: 0x41, count: 200), algo: .sha3_256),
        Case(key: "sha3_256_136_137", input: Data(repeating: 0x45, count: 137), algo: .sha3_256),
        Case(key: "sha3_224_empty", input: Data(), algo: .sha3_224),
        Case(key: "sha3_384_empty", input: Data(), algo: .sha3_384),
        Case(key: "sha3_512_empty", input: Data(), algo: .sha3_512),
        Case(key: "sha3_512_abc", input: Data("abc".utf8), algo: .sha3_512),
        Case(key: "shake128_empty_32", input: Data(), algo: .shake128(count: 32)),
        Case(key: "shake128_abc_64", input: Data("abc".utf8), algo: .shake128(count: 64)),
        Case(key: "shake128_exactrate", input: Data(repeating: 0x42, count: 168), algo: .shake128(count: 32)),
        Case(key: "shake256_empty_64", input: Data(), algo: .shake256(count: 64)),
        Case(key: "shake256_abc_32", input: Data("abc".utf8), algo: .shake256(count: 32)),
        Case(key: "shake256_136_136", input: Data(repeating: 0x43, count: 136), algo: .shake256(count: 136)),
        Case(key: "shake256_137_32", input: Data(repeating: 0x44, count: 137), algo: .shake256(count: 32)),
    ]

    static let expected: [String: String] = {
        guard let url = Bundle.module.url(forResource: "keccak_vectors", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let vectors = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return vectors
    }()

    /// The in-code table and the fixture must cover the same vectors.
    @Test func tableMatchesFixture() {
        #expect(Set(Self.allCases.map(\.key)) == Set(Self.expected.keys))
    }

    @Test(arguments: allCases)
    func vector(testCase: Case) throws {
        let expectedHex = try #require(Self.expected[testCase.key])
        let digest = testCase.algo.compute(testCase.input)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        #expect(hex == expectedHex)
    }
}
