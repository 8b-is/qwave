import XCTest
@testable import PostQuantum

/// Known-answer tests for the FIPS 202 Keccak family. Vectors generated with
/// Python's hashlib (which wraps the reference implementation) and committed
/// as a fixture; any drift in the Swift permutation fails here.
final class KeccakTests: XCTestCase {
    private var vectors: [String: String] = [:]

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "keccak_vectors", withExtension: "json"))
        let data = try Data(contentsOf: url)
        vectors = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    func testSHA3_256Vectors() throws {
        XCTAssertEqual(hex(Keccak.sha3_256(Data())), try XCTUnwrap(vectors["sha3_256_empty"]))
        XCTAssertEqual(hex(Keccak.sha3_256(Data("abc".utf8))), try XCTUnwrap(vectors["sha3_256_abc"]))
        XCTAssertEqual(
            hex(Keccak.sha3_256(Data(repeating: 0x41, count: 200))), try XCTUnwrap(vectors["sha3_256_2blocks"]))
        // rate = 136: 137 bytes crosses into the final padded block.
        XCTAssertEqual(
            hex(Keccak.sha3_256(Data(repeating: 0x45, count: 137))), try XCTUnwrap(vectors["sha3_256_136_137"]))
    }

    func testSHA3OtherSizes() throws {
        XCTAssertEqual(hex(Keccak.sha3_224(Data())), try XCTUnwrap(vectors["sha3_224_empty"]))
        XCTAssertEqual(hex(Keccak.sha3_384(Data())), try XCTUnwrap(vectors["sha3_384_empty"]))
        XCTAssertEqual(hex(Keccak.sha3_512(Data())), try XCTUnwrap(vectors["sha3_512_empty"]))
        XCTAssertEqual(hex(Keccak.sha3_512(Data("abc".utf8))), try XCTUnwrap(vectors["sha3_512_abc"]))
    }

    func testSHAKEVectors() throws {
        XCTAssertEqual(hex(Keccak.shake128(Data(), count: 32)), try XCTUnwrap(vectors["shake128_empty_32"]))
        XCTAssertEqual(hex(Keccak.shake128(Data("abc".utf8), count: 64)), try XCTUnwrap(vectors["shake128_abc_64"]))
        // exact rate boundary needs the extra padded block
        XCTAssertEqual(
            hex(Keccak.shake128(Data(repeating: 0x42, count: 168), count: 32)),
            try XCTUnwrap(vectors["shake128_exactrate"]))
        XCTAssertEqual(hex(Keccak.shake256(Data(), count: 64)), try XCTUnwrap(vectors["shake256_empty_64"]))
        XCTAssertEqual(hex(Keccak.shake256(Data("abc".utf8), count: 32)), try XCTUnwrap(vectors["shake256_abc_32"]))
        XCTAssertEqual(
            hex(Keccak.shake256(Data(repeating: 0x43, count: 136), count: 136)),
            try XCTUnwrap(vectors["shake256_136_136"]))
        XCTAssertEqual(
            hex(Keccak.shake256(Data(repeating: 0x44, count: 137), count: 32)),
            try XCTUnwrap(vectors["shake256_137_32"]))
    }
}
