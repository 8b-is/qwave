import XCTest
@testable import PostQuantum

/// Behavioural + NTT-algebra tests for FIPS 203 ML-KEM-768.
///
/// Conformance is proved elsewhere: `MLKEM768ACVPSuite` runs the official NIST
/// ACVP vectors. The self-generated round-trip fixtures that used to be loaded
/// here were removed — they only proved the implementation agreed with itself.
final class MLKEM768Tests: XCTestCase {

    // MARK: - Behavioural tests

    func testFullFlowRoundTrip() throws {
        let d = Data((0..<32).map { UInt8(($0 * 7) % 251) })
        let m = Data((0..<32).map { UInt8(($0 * 13) % 251) })
        let (ek, dk) = MLKEM768.keygen(d: d, z: Data(repeating: 0x11, count: 32))
        let (ct, ss) = try MLKEM768.encaps(ek: ek, m: m)
        XCTAssertEqual(MLKEM768.decaps(dk: dk, ct: ct), ss)
    }

    func testImplicitRejectionOnTamperedCiphertext() throws {
        let (ek, dk) = MLKEM768.keygen(d: Data(repeating: 0x5A, count: 32), z: Data(repeating: 0xA5, count: 32))
        let (ct, ss) = try MLKEM768.encaps(ek: ek, m: Data(repeating: 0x0F, count: 32))
        var tampered = ct
        tampered[tampered.count - 1] ^= 0x01
        XCTAssertNotEqual(tampered, ct)
        XCTAssertNotEqual(MLKEM768.decaps(dk: dk, ct: tampered), ss)
        // deterministic under the same bad ciphertext (z-based rejection)
        XCTAssertEqual(MLKEM768.decaps(dk: dk, ct: tampered), MLKEM768.decaps(dk: dk, ct: tampered))
    }

    /// Regression for #93: `encaps`/`decaps` used to index their `Data`
    /// arguments with absolute offsets, so a slice with a non-zero
    /// `startIndex` (e.g. a subrange carved out of a larger buffer) would
    /// trap instead of working like any other equal-content `Data`.
    func testEncapsDecapsAcceptNonZeroBasedSlices() throws {
        let d = Data((0..<32).map { UInt8(($0 * 7) % 251) })
        let m = Data((0..<32).map { UInt8(($0 * 13) % 251) })
        let (ek, dk) = MLKEM768.keygen(d: d, z: Data(repeating: 0x11, count: 32))

        // Pad each buffer with a junk prefix/suffix, then take the interior
        // slice back out. The slice is byte-for-byte identical to the
        // original, but its `startIndex` is > 0 — exactly the shape of Data
        // the old absolute-offset indexing couldn't handle.
        func nonZeroBasedSlice(_ data: Data) -> Data {
            var padded = Data(repeating: 0xEE, count: 7)
            padded.append(data)
            padded.append(Data(repeating: 0xEE, count: 5))
            let slice = padded[padded.startIndex.advanced(by: 7)..<padded.startIndex.advanced(by: 7 + data.count)]
            XCTAssertNotEqual(slice.startIndex, 0, "test fixture must produce a non-zero-based slice")
            XCTAssertEqual(Data(slice), data)
            return slice
        }

        let ekSlice = nonZeroBasedSlice(ek)
        let mSlice = nonZeroBasedSlice(m)
        let dkSlice = nonZeroBasedSlice(dk)

        let (ct, ss) = try MLKEM768.encaps(ek: ekSlice, m: mSlice)
        let ctSlice = nonZeroBasedSlice(ct)

        XCTAssertEqual(MLKEM768.decaps(dk: dkSlice, ct: ctSlice), ss)

        // Cross-check against the zero-based path to make sure the slice
        // variant isn't merely "not trapping" but actually correct.
        let (ctZero, ssZero) = try MLKEM768.encaps(ek: ek, m: m)
        XCTAssertEqual(ct, ctZero)
        XCTAssertEqual(ss, ssZero)
        XCTAssertEqual(MLKEM768.decaps(dk: dk, ct: ct), ssZero)
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
