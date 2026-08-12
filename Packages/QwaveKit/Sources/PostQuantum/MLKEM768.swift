import Foundation

/// FIPS 203 ML-KEM-768 (NIST post-quantum lattice KEM), parameter set
/// k=3, eta1=eta2=2, du=10, dv=4, q=3329, n=256.
///
/// Conventions follow the CRYSTALS reference implementation (which the
/// `ml-kem` Rust crate used by Mullvad is verified against):
///   - the matrix is sampled as A[i][j] = Parse(XOF(rho, nonce=(i<<8)|j))
///     with keygen, and as the transpose with encrypt (nonce=(j<<8)|i);
///   - PRF noise nonces follow FIPS 203's single counter (s: 0..k-1,
///     e: k..2k-1, y: 0..k-1, e1: k..2k-1, e2: 2k);
///   - Compress/Decompress are round-half-up (matching the reference).
///
/// Verified against independently generated vectors in `PostQuantumTests`.
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
    /// dk = ByteEncode_12(s) || ek || z || H(ek) (2400 bytes, FIPS 203 layout)
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

    static func byteDecode12(_ data: Data) -> [Int] {
        var out = [Int](repeating: 0, count: 256)
        for i in 0..<128 {
            let t = Int(data[3 * i]) | (Int(data[3 * i + 1]) << 8) | (Int(data[3 * i + 2]) << 16)
            out[2 * i] = t & 0xFFF
            out[2 * i + 1] = t >> 12
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
            let t = Int(data[5 * i])
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

    /// XOF(rho, nonce) -> 384-byte Parse into 256 coefficients.
    static func sampleMatrixEntry(_ rho: Data, nonce: Int) -> [Int] {
        var seed = Data(rho)
        seed.append(UInt8((nonce >> 8) & 0xFF))
        seed.append(UInt8(nonce & 0xFF))
        return byteDecode12(Keccak.shake128(seed, count: 384))
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

        var a = [[Int]](repeating: [Int](repeating: 0, count: 256), count: k * k)
        for i in 0..<k {
            for j in 0..<k {
                a[i * k + j] = sampleMatrixEntry(rho, nonce: (i << 8) | j)
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

        // Transposed matrix for u = A^T * y.
        var at = [[Int]](repeating: [Int](repeating: 0, count: 256), count: k * k)
        for i in 0..<k {
            for j in 0..<k {
                at[i * k + j] = sampleMatrixEntry(rho, nonce: (j << 8) | i)
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

    /// FIPS 203 Algorithm 16. d: 32-byte seed. Returns (ek, dk).
    public static func keygen(seed d: Data) -> (ek: Data, dk: Data) {
        precondition(d.count == 32)
        let z = Keccak.shake256(Data("qwave-z".utf8) + d, count: 32)
        let (ek, dkKPKE) = kpkeKeygen(d)
        var dk = dkKPKE
        dk.append(ek)
        dk.append(z)
        dk.append(Keccak.sha3_256(ek))
        return (ek, dk)
    }

    /// FIPS 203 Algorithm 17. m: 32-byte randomness. Returns (ct, ss).
    public static func encaps(ek: Data, m: Data) -> (ct: Data, ss: Data) {
        precondition(ek.count == ekSize && m.count == 32)
        let h = Keccak.shake256(ek, count: 32)
        let kR = Keccak.sha3_512(m + h)
        let k = kR.prefix(32)
        let r = Data(kR.dropFirst(32))
        let ct = kpkeEncrypt(ek, m, r)
        let ss = Keccak.shake256(k + ct, count: 32)
        return (ct, ss)
    }

    /// FIPS 203 Algorithm 18 (with implicit rejection). Returns ss.
    public static func decaps(dk: Data, ct: Data) -> Data {
        precondition(dk.count == dkSize && ct.count == ctSize)
        let dkKPKE = dk.prefix(384 * k)
        let ek = dk.subdata(in: (384 * k)..<(384 * k + ekSize))
        let z = dk.subdata(in: (384 * k + ekSize)..<(384 * k + ekSize + 32))

        let m2 = kpkeDecrypt(dkKPKE, ct)
        let h = Keccak.shake256(ek, count: 32)
        let k2R = Keccak.sha3_512(m2 + h)
        let k2 = k2R.prefix(32)
        let r2 = Data(k2R.dropFirst(32))
        let ct2 = kpkeEncrypt(ek, m2, r2)
        if ct2 == ct {
            return Keccak.shake256(k2 + ct, count: 32)
        }
        return Keccak.shake256(z + ct, count: 32)
    }
}
