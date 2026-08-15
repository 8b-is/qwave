import Foundation

/// FIPS 203 ML-KEM-768 (NIST post-quantum lattice KEM), parameter set
/// k=3, eta1=eta2=2, du=10, dv=4, q=3329, n=256.
///
/// Conventions follow FIPS 203 final (and therefore the CRYSTALS reference
/// implementation, which the `ml-kem` Rust crate used by Mullvad is verified
/// against):
///   - the matrix is sampled with rejection sampling (Algorithm 7) as
///     Â[i][j] = SampleNTT(rho ‖ j ‖ i) in KeyGen, and as the transpose
///     Â[i][j] = SampleNTT(rho ‖ i ‖ j) in Encrypt;
///   - PRF noise nonces follow FIPS 203's single counter (s: 0..k-1,
///     e: k..2k-1, y: 0..k-1, e1: k..2k-1, e2: 2k);
///   - Compress/Decompress are round-half-up (matching the reference);
///   - Encaps returns K directly — the Kyber-round-3 KDF over (K ‖ c) was
///     removed during standardisation.
///
/// Conformance evidence: the official NIST ACVP ML-KEM-768 vectors, in
/// `PostQuantumTests/MLKEM768ACVPSuite`.
public enum MLKEM768 {
    public static let q = 3329
    static let n = 256
    static let k = 3
    static let eta1 = 2
    static let eta2 = 2
    static let du = 10
    static let dv = 4

    /// ek = ByteEncode_12(t) || rho (1184 bytes)
    public static let ekSize = 384 * k + 32
    /// dk = ByteEncode_12(s) || ek || H(ek) || z (2400 bytes, FIPS 203 Alg 16)
    public static let dkSize = 384 * k + ekSize + 32 + 32
    /// ct = ByteEncode_10(u) || ByteEncode_4(v) (1088 bytes)
    public static let ctSize = 320 * k + 128
    public static let ssSize = 32

    // MARK: - NTT

    /// zetas[i] = 17^BitRev7(i) mod q (FIPS 203 Algorithm 7).
    static let zetas: [Int] = {
        var z = [Int](repeating: 0, count: 128)
        for i in 0..<128 {
            z[i] = powmod(17, bitRev7(i), q)
        }
        return z
    }()

    static func bitRev7(_ i: Int) -> Int {
        var x = i
        var r = 0
        for _ in 0..<7 {
            r = (r << 1) | (x & 1)
            x >>= 1
        }
        return r
    }

    static func powmod(_ base: Int, _ exp: Int, _ mod: Int) -> Int {
        var result = 1
        var b = base % mod
        var e = exp
        while e > 0 {
            if e & 1 == 1 {
                result = (result * b) % mod
            }
            b = (b * b) % mod
            e >>= 1
        }
        return result
    }

    /// FIPS 203 Algorithm 8. Natural order in, natural order out.
    static func ntt(_ input: [Int]) -> [Int] {
        var f = input
        var k = 1
        var len = 128
        while len >= 2 {
            for start in stride(from: 0, to: n, by: 2 * len) {
                let zeta = zetas[k]
                k += 1
                for j in start..<(start + len) {
                    let t = (zeta * f[j + len]) % q
                    f[j + len] = ((f[j] - t) % q + q) % q
                    f[j] = (f[j] + t) % q
                }
            }
            len /= 2
        }
        return f
    }

    /// FIPS 203 Algorithm 9 (includes the n^-1 = 3316 scaling).
    static func intt(_ input: [Int]) -> [Int] {
        var f = input
        var k = 127
        var len = 2
        while len <= 128 {
            for start in stride(from: 0, to: n, by: 2 * len) {
                let zeta = zetas[k]
                k -= 1
                for j in start..<(start + len) {
                    let t = f[j]
                    f[j] = (t + f[j + len]) % q
                    f[j + len] = (zeta * ((f[j + len] - t) % q + q)) % q
                }
            }
            len *= 2
        }
        // Final scale: 128^-1 mod q = 3303. The FIPS 203 NTT factors into two
        // 128-point transforms (even/odd parity classes), so the inverse
        // carries 1/128 per class — not 1/256.
        let scale = 3303
        return f.map { ($0 * scale) % q }
    }

    /// FIPS 203 NTT-domain multiplication (basemul): component i is the product
    /// in R/(X^2 - zeta^(2*BitRev7(i)+1)). Plain pointwise multiplication of
    /// NTT outputs is NOT the product of the underlying polynomials.
    static func basemul(_ a: [Int], _ b: [Int]) -> [Int] {
        var out = [Int](repeating: 0, count: 256)
        for i in 0..<128 {
            let zeta = powmod(17, 2 * bitRev7(i) + 1, q)
            out[2 * i] = (a[2 * i] * b[2 * i] + zeta * a[2 * i + 1] * b[2 * i + 1]) % q
            out[2 * i + 1] = (a[2 * i] * b[2 * i + 1] + a[2 * i + 1] * b[2 * i]) % q
        }
        return out
    }

    static func polyAdd(_ a: [Int], _ b: [Int]) -> [Int] {
        zip(a, b).map { ($0 + $1) % q }
    }

    // MARK: - Byte encoding

    static func byteEncode12(_ f: [Int]) -> Data {
        var out = Data(capacity: 384)
        var i = 0
        while i < 256 {
            let t = f[i] | (f[i + 1] << 12)
            out.append(UInt8(t & 0xFF))
            out.append(UInt8((t >> 8) & 0xFF))
            out.append(UInt8(t >> 16))
            i += 2
        }
        return out
    }

    /// FIPS 203 Algorithm 6 (ByteDecode_12). For d = 12 the modulus is q, not
    /// 2^12, so the decoded values are reduced mod q — a 12-bit field can hold
    /// 767 values that are not valid coefficients.
    static func byteDecode12(_ data: Data) -> [Int] {
        var out = [Int](repeating: 0, count: 256)
        for i in 0..<128 {
            let t = Int(data[3 * i]) | (Int(data[3 * i + 1]) << 8) | (Int(data[3 * i + 2]) << 16)
            out[2 * i] = (t & 0xFFF) % q
            out[2 * i + 1] = (t >> 12) % q
        }
        return out
    }

    static func byteEncode10(_ f: [Int]) -> Data {
        var out = Data(capacity: 320)
        for i in 0..<64 {
            var t = 0
            for j in 0..<4 {
                t |= f[4 * i + j] << (10 * j)
            }
            out.append(UInt8(t & 0xFF))
            out.append(UInt8((t >> 8) & 0xFF))
            out.append(UInt8((t >> 16) & 0xFF))
            out.append(UInt8((t >> 24) & 0xFF))
            out.append(UInt8((t >> 32) & 0xFF))
        }
        return out
    }

    static func byteDecode10(_ data: Data) -> [Int] {
        var out = [Int](repeating: 0, count: 256)
        for i in 0..<64 {
            let t =
                Int(data[5 * i])
                | (Int(data[5 * i + 1]) << 8)
                | (Int(data[5 * i + 2]) << 16)
                | (Int(data[5 * i + 3]) << 24)
                | (Int(data[5 * i + 4]) << 32)
            for j in 0..<4 {
                out[4 * i + j] = (t >> (10 * j)) & 0x3FF
            }
        }
        return out
    }

    static func byteEncode4(_ f: [Int]) -> Data {
        var out = Data(capacity: 128)
        for i in 0..<128 {
            out.append(UInt8(f[2 * i] | (f[2 * i + 1] << 4)))
        }
        return out
    }

    static func byteDecode4(_ data: Data) -> [Int] {
        var out = [Int](repeating: 0, count: 256)
        for i in 0..<128 {
            let b = Int(data[i])
            out[2 * i] = b & 0xF
            out[2 * i + 1] = b >> 4
        }
        return out
    }

    static func byteEncode1(_ f: [Int]) -> Data {
        var out = Data(capacity: 32)
        for i in 0..<32 {
            var b = 0
            for j in 0..<8 {
                b |= f[8 * i + j] << j
            }
            out.append(UInt8(b))
        }
        return out
    }

    static func byteDecode1(_ data: Data) -> [Int] {
        var out = [Int](repeating: 0, count: 256)
        for i in 0..<32 {
            let b = Int(data[i])
            for j in 0..<8 {
                out[8 * i + j] = (b >> j) & 1
            }
        }
        return out
    }

    // MARK: - Compress / sampling

    static func compress(_ x: Int, _ d: Int) -> Int {
        (((x << d) + q / 2) / q) & ((1 << d) - 1)
    }

    static func decompress(_ y: Int, _ d: Int) -> Int {
        (y * q + (1 << (d - 1))) >> d
    }

    /// CRYSTALS CBD: coefficient i reads bits [2*eta*i, 2*eta*i+2*eta).
    static func cbd(_ eta: Int, _ input: Data) -> [Int] {
        var f = [Int](repeating: 0, count: 256)
        for i in 0..<256 {
            let base = 2 * eta * i
            var x = 0
            var y = 0
            for j in 0..<eta {
                let bit = base + j
                x += (Int(input[bit >> 3]) >> (bit & 7)) & 1
            }
            for j in 0..<eta {
                let bit = base + eta + j
                y += (Int(input[bit >> 3]) >> (bit & 7)) & 1
            }
            f[i] = ((x - y) % q + q) % q
        }
        return f
    }

    /// FIPS 203 Algorithm 7 (SampleNTT): rejection sampling from
    /// SHAKE128(rho ‖ b0 ‖ b1).
    ///
    /// The XOF stream is read three bytes at a time into two 12-bit values
    /// d1, d2; each is ACCEPTED only if it is < q, otherwise it is discarded
    /// and more stream is read. A fixed-size squeeze that keeps every 12-bit
    /// value would admit the 767 values in [q, 2^12) and produce a different
    /// matrix from every conformant implementation.
    ///
    /// The number of bytes consumed is unbounded in principle (>575 bytes
    /// happens with probability ~2^-38), which is why this streams from
    /// `Keccak.SHAKE128Reader` instead of over-squeezing a fixed block.
    static func sampleNTT(_ rho: Data, _ b0: Int, _ b1: Int) -> [Int] {
        var seed = Data(rho)
        seed.append(UInt8(b0))
        seed.append(UInt8(b1))
        var reader = Keccak.SHAKE128Reader(seed)

        var a = [Int](repeating: 0, count: n)
        var j = 0
        while j < n {
            let c = reader.read(3)
            let d1 = Int(c[0]) | ((Int(c[1]) & 0xF) << 8)
            let d2 = (Int(c[1]) >> 4) | (Int(c[2]) << 4)
            if d1 < q {
                a[j] = d1
                j += 1
            }
            if d2 < q && j < n {
                a[j] = d2
                j += 1
            }
        }
        return a
    }

    static func sampleNoise(_ seed: Data, nonce: Int, eta: Int) -> [Int] {
        var input = Data(seed)
        input.append(UInt8(nonce))
        return cbd(eta, Keccak.shake256(input, count: 64 * eta))
    }

    // MARK: - K-PKE

    static func kpkeKeygen(_ d: Data) -> (ek: Data, dk: Data) {
        var dkSeed = Data(d)
        dkSeed.append(UInt8(k))
        let rhoSigma = Keccak.sha3_512(dkSeed)
        let rho = rhoSigma.prefix(32)
        let sigma = Data(rhoSigma.dropFirst(32))

        // FIPS 203 Algorithm 13 step 10: Â[i,j] ← SampleNTT(ρ ‖ j ‖ i).
        // The two index bytes are (j, i) here and (i, j) in Encrypt; getting
        // them the same way round in both places yields a self-consistent but
        // non-interoperable KEM.
        var a = [[Int]](repeating: [Int](repeating: 0, count: 256), count: k * k)
        for i in 0..<k {
            for j in 0..<k {
                a[i * k + j] = sampleNTT(rho, j, i)
            }
        }

        var s = [[Int]]()
        var e = [[Int]]()
        for i in 0..<k {
            s.append(sampleNoise(sigma, nonce: i, eta: eta1))
            e.append(sampleNoise(sigma, nonce: k + i, eta: eta1))
        }

        let sHat = s.map(ntt)
        let eHat = e.map(ntt)

        // tHat[i] = sum_j A[i][j] ∘ sHat[j] + eHat[i]  (basemul in NTT domain)
        var tHat = [[Int]](repeating: [Int](repeating: 0, count: 256), count: k)
        for i in 0..<k {
            var acc = [Int](repeating: 0, count: 256)
            for j in 0..<k {
                acc = polyAdd(acc, basemul(a[i * k + j], sHat[j]))
            }
            tHat[i] = polyAdd(acc, eHat[i])
        }

        var ek = Data()
        for i in 0..<k {
            ek.append(byteEncode12(tHat[i]))
        }
        ek.append(rho)

        var dk = Data()
        for i in 0..<k {
            dk.append(byteEncode12(sHat[i]))
        }
        return (ek, dk)
    }

    static func kpkeEncrypt(_ ek: Data, _ m: Data, _ r: Data) -> Data {
        var t = [[Int]]()
        for i in 0..<k {
            t.append(byteDecode12(ek.subdata(in: (384 * i)..<(384 * (i + 1)))))
        }
        let rho = ek.subdata(in: (384 * k)..<ek.count)

        // Transposed matrix for u = A^T ∘ y: (Â^⊤)[i,j] = Â[j,i] =
        // SampleNTT(ρ ‖ i ‖ j) — index bytes (i, j), the mirror of KeyGen.
        var at = [[Int]](repeating: [Int](repeating: 0, count: 256), count: k * k)
        for i in 0..<k {
            for j in 0..<k {
                at[i * k + j] = sampleNTT(rho, i, j)
            }
        }

        var y = [[Int]]()
        var e1 = [[Int]]()
        for i in 0..<k {
            y.append(sampleNoise(r, nonce: i, eta: eta1))
            e1.append(sampleNoise(r, nonce: k + i, eta: eta2))
        }
        let e2 = sampleNoise(r, nonce: 2 * k, eta: eta2)
        let yHat = y.map(ntt)

        var u = [[Int]](repeating: [Int](repeating: 0, count: 256), count: k)
        for i in 0..<k {
            var acc = [Int](repeating: 0, count: 256)
            for j in 0..<k {
                acc = polyAdd(acc, basemul(at[i * k + j], yHat[j]))
            }
            u[i] = polyAdd(intt(acc), e1[i])
        }

        let mu = byteDecode1(m).map { decompress($0, 1) }
        var v = [Int](repeating: 0, count: 256)
        for i in 0..<k {
            v = polyAdd(v, intt(basemul(t[i], yHat[i])))
        }
        v = polyAdd(polyAdd(v, e2), mu)

        var ct = Data()
        for i in 0..<k {
            ct.append(byteEncode10(u[i].map { compress($0, du) }))
        }
        ct.append(byteEncode4(v.map { compress($0, dv) }))
        return ct
    }

    static func kpkeDecrypt(_ dk: Data, _ ct: Data) -> Data {
        var s = [[Int]]()
        for i in 0..<k {
            s.append(byteDecode12(dk.subdata(in: (384 * i)..<(384 * (i + 1)))))
        }
        var u = [[Int]]()
        for i in 0..<k {
            u.append(byteDecode10(ct.subdata(in: (320 * i)..<(320 * (i + 1)))).map { decompress($0, du) })
        }
        let v = byteDecode4(ct.subdata(in: (320 * k)..<ct.count)).map { decompress($0, dv) }

        var w = [Int](repeating: 0, count: 256)
        for i in 0..<k {
            w = polyAdd(w, intt(basemul(s[i], ntt(u[i]))))
        }
        for i in 0..<256 {
            w[i] = ((v[i] - w[i]) % q + q) % q
        }
        return byteEncode1(w.map { compress($0, 1) })
    }

    // MARK: - ML-KEM

    public enum MLKEMError: Error, Equatable {
        /// FIPS 203 §7.2 encapsulation-key input check failed: wrong length, or
        /// a coefficient outside [0, q) (the "modulus check").
        case invalidEncapsulationKey
    }

    /// FIPS 203 §7.2 encapsulation-key input check: the type check (length)
    /// and the modulus check (every encoded coefficient is already reduced,
    /// i.e. re-encoding the decoded key reproduces it byte for byte).
    public static func validateEncapsulationKey(_ ekIn: Data) -> Bool {
        let ek = Data(ekIn)
        guard ek.count == ekSize else { return false }
        for i in 0..<k {
            let chunk = ek.subdata(in: (384 * i)..<(384 * (i + 1)))
            if byteEncode12(byteDecode12(chunk)) != chunk { return false }
        }
        return true
    }

    /// FIPS 203 Algorithm 16 (ML-KEM.KeyGen_internal). d and z are two
    /// *independent* 32-byte seeds — z is the implicit-rejection secret and the
    /// standard never derives it from d.
    public static func keygen(d: Data, z: Data) -> (ek: Data, dk: Data) {
        precondition(d.count == 32 && z.count == 32)
        let (ek, dkKPKE) = kpkeKeygen(d)
        // dk ← dk_PKE ‖ ek ‖ H(ek) ‖ z  (Algorithm 16 step 3).
        var dk = dkKPKE
        dk.append(ek)
        dk.append(Keccak.sha3_256(ek))
        dk.append(z)
        return (ek, dk)
    }

    /// FIPS 203 Algorithm 17 (ML-KEM.Encaps_internal), preceded by the §7.2
    /// input check. m: 32-byte randomness. Returns (ct, ss).
    ///
    /// `ek`/`m` are rebased to zero-based `Data` up front — `kpkeEncrypt` (and
    /// the byte decoders it calls) index with absolute offsets, so a
    /// caller-supplied slice with a non-zero `startIndex` (e.g. a subrange of
    /// a larger buffer) would otherwise trap instead of failing gracefully.
    public static func encaps(ek ekIn: Data, m mIn: Data) throws -> (ct: Data, ss: Data) {
        let ek = Data(ekIn)
        let m = Data(mIn)
        precondition(m.count == 32)
        guard validateEncapsulationKey(ek) else { throw MLKEMError.invalidEncapsulationKey }
        // H is SHA3-256 (FIPS 203 §4.1), not SHAKE256. H(ek) feeds G(m ‖ H(ek)),
        // which yields both K and the encryption coins r.
        let h = Keccak.sha3_256(ek)
        let kR = Keccak.sha3_512(m + h)
        let ss = kR.prefix(32)
        let r = Data(kR.dropFirst(32))
        let ct = kpkeEncrypt(ek, m, r)
        // K is returned directly. The Kyber-round-3 ss = KDF(K ‖ c) step was
        // REMOVED during standardisation; keeping it breaks every peer.
        return (ct, Data(ss))
    }

    /// FIPS 203 Algorithm 18 (ML-KEM.Decaps_internal, with implicit
    /// rejection). Returns ss.
    ///
    /// `dk`/`ct` are rebased to zero-based `Data` up front for the same
    /// reason as `encaps`: this function and `kpkeDecrypt`/`kpkeEncrypt` slice
    /// with absolute offsets, which only holds if the input's `startIndex` is
    /// 0. Without the rebase, a non-zero-based slice traps.
    public static func decaps(dk dkIn: Data, ct ctIn: Data) -> Data {
        let dk = Data(dkIn)
        let ct = Data(ctIn)
        precondition(dk.count == dkSize && ct.count == ctSize)
        let dkKPKE = dk.prefix(384 * k)
        let ek = dk.subdata(in: (384 * k)..<(384 * k + ekSize))
        // dk layout is dk_PKE ‖ ek ‖ H(ek) ‖ z; h is *read*, not recomputed.
        let h = dk.subdata(in: (384 * k + ekSize)..<(384 * k + ekSize + 32))
        let z = dk.subdata(in: (384 * k + ekSize + 32)..<(384 * k + ekSize + 64))

        let m2 = kpkeDecrypt(dkKPKE, ct)
        let k2R = Keccak.sha3_512(m2 + h)
        let k2 = k2R.prefix(32)
        let r2 = Data(k2R.dropFirst(32))
        let ct2 = kpkeEncrypt(ek, m2, r2)
        // Rejection secret K̄ = J(z ‖ c) = SHAKE256(z ‖ c, 32).
        let kBar = Keccak.shake256(z + ct, count: 32)

        // FIPS 203 implicit rejection, constant time: the re-encryption
        // comparison must not early-exit and the K'-vs-K̄ selection must not
        // branch — both operate on secret-derived data.
        var acc: UInt8 = 0
        for (a, b) in zip(ct2, ct) {
            acc |= a ^ b
        }
        let accWide = UInt16(acc)
        let isTampered = UInt8((accWide | (0 &- accWide)) >> 8) & 1
        let mask = 0 &- isTampered  // 0x00 accept (K'), 0xFF reject (K̄)
        var selected = Data(count: 32)
        for (i, pair) in zip(k2, kBar).enumerated() {
            selected[i] = pair.0 ^ (mask & (pair.0 ^ pair.1))
        }
        return selected
    }
}
