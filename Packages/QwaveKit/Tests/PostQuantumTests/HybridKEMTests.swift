import XCTest
@testable import PostQuantum

/// Behavioural tests for the tunnel-PSK KEM wrapper.
///
/// There are deliberately no known-answer vectors here: `HybridKEM` is a local
/// domain-separated wrapper, not a standardised construction, so a fixture
/// would only restate what this code does. The conformance evidence lives in
/// `MLKEM768ACVPSuite` against the official NIST ACVP vectors; these tests
/// cover the wrapper's own behaviour.
final class HybridKEMTests: XCTestCase {
    func testKeySizes() {
        XCTAssertEqual(HybridKEM.ekSize, 1_184)
        XCTAssertEqual(HybridKEM.dkSize, 2_400)
        XCTAssertEqual(HybridKEM.ctSize, 1_088)
        XCTAssertEqual(HybridKEM.ssSize, 32)
    }

    func testFullFlowRoundTrip() throws {
        let seed = Data((0..<32).map { UInt8(($0 * 17 + 5) % 251) })
        let (ek, dk) = try HybridKEM.keygen(seed: seed)
        let (ct, ss) = try HybridKEM.encapsulate(ek: ek, seed: seed)
        let ss2 = try HybridKEM.decapsulate(dk: dk, ct: ct)
        XCTAssertEqual(ss2, ss)
    }

    func testKeygenIsDeterministic() throws {
        let seed = Data(repeating: 0x42, count: 32)
        let (ek1, dk1) = try HybridKEM.keygen(seed: seed)
        let (ek2, dk2) = try HybridKEM.keygen(seed: seed)
        XCTAssertEqual(ek1, ek2)
        XCTAssertEqual(dk1, dk2)
    }

    /// A wrong decapsulation key does not throw — ML-KEM implicit rejection
    /// yields a *different* secret, deterministically, and the WireGuard
    /// handshake is what fails.
    func testWrongKeyYieldsDifferentSecret() throws {
        let (ek, _) = try HybridKEM.keygen(seed: Data(repeating: 0x01, count: 32))
        let (_, wrongDk) = try HybridKEM.keygen(seed: Data(repeating: 0x02, count: 32))
        let (ct, ss) = try HybridKEM.encapsulate(ek: ek, seed: Data(repeating: 0x03, count: 32))
        let rejected = try HybridKEM.decapsulate(dk: wrongDk, ct: ct)
        XCTAssertNotEqual(rejected, ss)
        XCTAssertEqual(rejected, try HybridKEM.decapsulate(dk: wrongDk, ct: ct))
    }

    func testDifferentSeedsDiffer() throws {
        let seedA = Data(repeating: 0xAA, count: 32)
        let seedB = Data(repeating: 0xBB, count: 32)
        let (ekA, dkA) = try HybridKEM.keygen(seed: seedA)
        let (ekB, _) = try HybridKEM.keygen(seed: seedB)
        XCTAssertNotEqual(ekA, ekB)
        let (ctA, ssA) = try HybridKEM.encapsulate(ek: ekA, seed: seedA)
        let (ctB, ssB) = try HybridKEM.encapsulate(ek: ekB, seed: seedB)
        XCTAssertNotEqual(ctA, ctB)
        XCTAssertNotEqual(ssA, ssB)
        XCTAssertEqual(try HybridKEM.decapsulate(dk: dkA, ct: ctA), ssA)
    }

    /// The PSK must not be the raw ML-KEM shared secret: the domain-separating
    /// label is what keeps this key distinct from any other use of the KEM.
    func testPSKIsDomainSeparatedFromRawKEMSecret() throws {
        let seed = Data(repeating: 0x7E, count: 32)
        let (ek, _) = try HybridKEM.keygen(seed: seed)
        let (ct, ss) = try HybridKEM.encapsulate(ek: ek, seed: seed)
        let m = Keccak.shake256(Data("qwave/mlkem-enc".utf8) + seed, count: 32)
        let (rawCt, rawSS) = try MLKEM768.encaps(ek: ek, m: m)
        XCTAssertEqual(rawCt, ct)
        XCTAssertNotEqual(rawSS, ss)
    }
}
