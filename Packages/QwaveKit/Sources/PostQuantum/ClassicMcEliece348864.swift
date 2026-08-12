import Foundation

/// Classic McEliece 348864 (NIST round-3 parameter set): a code-based
/// post-quantum KEM over binary Goppa codes.
///
///   m = 12, n = 3488, t = 64, k = n - m*t = 2720, GF(2^12), f = 0x1053
///   (x^12 + x^6 + x^5 + x + 1, verified irreducible; 2 is primitive).
///
/// Layouts (cross-checked against the vector oracle `mceliece_ref.py`):
///   ek = bit-packed (n-k) x k systematic parity matrix P   (261120 bytes)
///   dk = g (98) || physical support (5232)                 (5330 bytes)
///   ct = n/8 = 436 bytes, ss = 32 bytes
///
/// The keygen column permutation is folded into the support (S_phys[p] =
/// L[perm[p]]), so the code's syndrome matrix in natural order is exactly the
/// systematic [I | P] form — neither encryption nor decryption needs a
/// permutation, matching the reference construction.
///
/// Decapsulation verifies that the corrected word is a codeword (zero
/// syndrome), so a decoding failure throws instead of yielding a wrong key;
/// the caller falls back to classic WireGuard.
public enum ClassicMcEliece348864 {
    public static let m = 12
    public static let n = 3488
    public static let t = 64
    public static let k = 2720
    static let nk = m * t // 768
    static let fieldPoly = 0x1053
    static let gfMask = 0xFFF

    public static let ekSize = nk * k / 8
    /// dk = g (65 coeffs × 12 bits = 98 bytes) || support (3488 × 12 bits = 5232 bytes)
    public static let dkSize = 98 + n * m / 8
    public static let ctSize = n / 8
    public static let ssSize = 32

    public enum McElieceError: Error {
        case rankDeficient
        case decodingFailure
        case nonInvertible
    }

    // MARK: - GF(2^12)

    /// antilog[i] = 2^i mod f; 2 is primitive, so multiplication and
    /// inversion are table lookups.
    static let antilog: [UInt16] = {
        var table = [UInt16](repeating: 0, count: 4096)
        var v: UInt32 = 1
        for i in 0..<4095 {
            table[i] = UInt16(v)
            v <<= 1
            if v & (1 << m) != 0 {
                v ^= UInt32(fieldPoly)
            }
        }
        return table
    }()

    static let log: [UInt16] = {
        var table = [UInt16](repeating: 0, count: 4096)
        for i in 0..<4095 {
            table[Int(antilog[i])] = UInt16(i)
        }
        return table
    }()

    static func gfMul(_ a: UInt16, _ b: UInt16) -> UInt16 {
        guard a != 0, b != 0 else { return 0 }
        return antilog[(Int(log[Int(a)]) + Int(log[Int(b)])) % 4095]
    }

    static func gfSquare(_ a: UInt16) -> UInt16 {
        gfMul(a, a)
    }

    static func gfInverse(_ a: UInt16) throws -> UInt16 {
        guard a != 0 else { throw McElieceError.nonInvertible }
        return antilog[(4095 - Int(log[Int(a)])) % 4095]
    }

    // MARK: - Polynomials over GF(2^12) (low index = low degree)

    static func polyTrim(_ p: [UInt16]) -> [UInt16] {
        var q = p
        while q.count > 1 && q.last == 0 {
            q.removeLast()
        }
        return q
    }

    static func polyAdd(_ a: [UInt16], _ b: [UInt16]) -> [UInt16] {
        let count = max(a.count, b.count)
        var out = [UInt16](repeating: 0, count: count)
        for i in 0..<count {
            out[i] = (i < a.count ? a[i] : 0) ^ (i < b.count ? b[i] : 0)
        }
        return polyTrim(out)
    }

    static func polyMul(_ a: [UInt16], _ b: [UInt16]) -> [UInt16] {
        var out = [UInt16](repeating: 0, count: a.count + b.count - 1)
        for i in 0..<a.count where a[i] != 0 {
            for j in 0..<b.count where b[j] != 0 {
                out[i + j] ^= gfMul(a[i], b[j])
            }
        }
        return polyTrim(out)
    }

    static func polyDivMod(_ a: [UInt16], _ b: [UInt16]) throws -> (q: [UInt16], r: [UInt16]) {
        var a = a
        let b = polyTrim(b)
        guard b.count > 0, b.last != 0 else { throw McElieceError.nonInvertible }
        var q = [UInt16](repeating: 0, count: max(0, a.count - b.count + 1))
        while a.count >= b.count {
            let coeff = gfMul(a[a.count - 1], try gfInverse(b[b.count - 1]))
            q[a.count - b.count] = coeff
            let shift = a.count - b.count
            for j in 0..<b.count {
                a[shift + j] ^= gfMul(coeff, b[j])
            }
            while a.count > 0 && a.last == 0 {
                a.removeLast()
            }
        }
        return (polyTrim(q), a.isEmpty ? [0] : polyTrim(a))
    }

    static func polyMod(_ a: [UInt16], _ b: [UInt16]) throws -> [UInt16] {
        try polyDivMod(a, b).r
    }

    static func polyGcd(_ a: [UInt16], _ b: [UInt16]) throws -> [UInt16] {
        var a = polyTrim(a)
        var b = polyTrim(b)
        while b != [0] {
            let r = try polyMod(a, b)
            a = b
            b = r
        }
        if a.count == 1 && a[0] != 0 {
            return [1]
        }
        let lead = try gfInverse(a[a.count - 1])
        return polyTrim(a.map { gfMul($0, lead) })
    }

    static func polyDerivative(_ a: [UInt16]) -> [UInt16] {
        guard a.count > 1 else { return [0] }
        var out = [UInt16](repeating: 0, count: a.count - 1)
        for i in 1..<a.count where i % 2 == 1 {
            out[i - 1] = a[i]
        }
        return polyTrim(out)
    }

    static func polyEvaluate(_ p: [UInt16], at x: UInt16) -> UInt16 {
        var r: UInt16 = 0
        for c in p.reversed() {
            r = gfMul(r, x) ^ c
        }
        return r
    }

    static func polySquare(_ p: [UInt16]) -> [UInt16] {
        var out = [UInt16](repeating: 0, count: 2 * p.count - 1)
        for i in 0..<p.count {
            out[2 * i] = gfSquare(p[i])
        }
        return polyTrim(out)
    }

    /// Inverse of `a` modulo `m` (throws when gcd != 1).
    static func polyInverse(_ a: [UInt16], mod m: [UInt16]) throws -> [UInt16] {
        let a = try polyMod(a, m)
        guard a != [0] else { throw McElieceError.nonInvertible }
        var r0 = m
        var r1 = a
        var v0: [UInt16] = [0]
        var v1: [UInt16] = [1]
        while r1 != [0] {
            let (q, r) = try polyDivMod(r0, r1)
            r0 = r1
            r1 = r
            let newV1 = polyAdd(v0, polyMul(q, v1))
            v0 = v1
            v1 = newV1
        }
        guard r0.count == 1, r0[0] != 0 else { throw McElieceError.nonInvertible }
        let scale = try gfInverse(r0[0])
        return try polyMod(v0.map { gfMul($0, scale) }, m)
    }

    /// Inverses of many polynomials mod m: one inversion + prefix products.
    static func batchInverse(_ polys: [[UInt16]], mod m: [UInt16]) throws -> [[UInt16]] {
        let count = polys.count
        guard count > 0 else { return [] }
        var prefix = [[UInt16]](repeating: [1], count: count)
        var acc: [UInt16] = [1]
        for i in 0..<count {
            acc = try polyMod(polyMul(acc, polys[i]), m)
            prefix[i] = acc
        }
        var q = try polyInverse(prefix[count - 1], mod: m)
        var out = [[UInt16]](repeating: [0], count: count)
        for i in stride(from: count - 1, through: 0, by: -1) {
            out[i] = try polyMod(polyMul(i > 0 ? prefix[i - 1] : [1], q), m)
            q = try polyMod(polyMul(q, polys[i]), m)
        }
        return out
    }

    // MARK: - Bit helpers

    static func bit(_ words: [UInt64], _ position: Int) -> Bool {
        (words[position >> 6] >> (position & 63)) & 1 == 1
    }

    static func setBit(_ words: inout [UInt64], _ position: Int) {
        words[position >> 6] |= 1 << (position & 63)
    }

    static func packBits(_ bits: [Bool]) -> Data {
        var out = Data(capacity: (bits.count + 7) / 8)
        var byte: UInt8 = 0
        for (i, bit) in bits.enumerated() {
            if bit { byte |= 1 << (i & 7) }
            if i & 7 == 7 {
                out.append(byte)
                byte = 0
            }
        }
        if bits.count % 8 != 0 {
            out.append(byte)
        }
        return out
    }

    static func packFieldElements(_ values: [UInt16]) -> Data {
        var out = Data()
        var acc: UInt32 = 0
        var accBits = 0
        for v in values {
            acc |= UInt32(v) << accBits
            accBits += 12
            while accBits >= 8 {
                out.append(UInt8(acc & 0xFF))
                acc >>= 8
                accBits -= 8
            }
        }
        if accBits > 0 {
            out.append(UInt8(acc & 0xFF))
        }
        return out
    }

    static func unpackFieldElements(_ data: Data, count: Int) -> [UInt16] {
        var out = [UInt16](repeating: 0, count: count)
        var acc: UInt32 = 0
        var accBits = 0
        var index = 0
        for byte in data {
            acc |= UInt32(byte) << accBits
            accBits += 8
            while accBits >= 12 && index < count {
                out[index] = UInt16(acc & 0xFFF)
                acc >>= 12
                accBits -= 12
                index += 1
            }
        }
        return out
    }

    // MARK: - Key generation

    static func readU16(_ stream: [UInt8], _ offset: inout Int) -> UInt16 {
        let v = UInt16(stream[offset]) | (UInt16(stream[offset + 1]) << 8)
        offset += 2
        return v
    }

    static func sampleGoppaPoly(stream: [UInt8], offset: inout Int) throws -> [UInt16] {
        while true {
            var g = [UInt16](repeating: 0, count: t + 1)
            for i in 0..<t {
                g[i] = readU16(stream, &offset) & UInt16(gfMask)
            }
            g[t] = 1
            if try polyGcd(g, polyDerivative(g)) == [1] {
                return g
            }
        }
    }

    static func sampleSupport(stream: [UInt8], offset: inout Int, g: [UInt16]) -> [UInt16] {
        while true {
            var support = [UInt16]()
            var seen = Set<UInt16>()
            var ok = true
            while support.count < n {
                let v = readU16(stream, &offset) & UInt16(gfMask)
                if seen.contains(v) { continue }
                if polyEvaluate(g, at: v) == 0 {
                    ok = false
                    break
                }
                seen.insert(v)
                support.append(v)
            }
            if ok {
                return support
            }
        }
    }

    /// Syndrome matrix rows: bit [coeff*12 + b] of (x + L_j)^-1 mod g.
    static func syndromeRows(g: [UInt16], support: [UInt16]) throws -> [[UInt64]] {
        let linearFactors = support.map { [$0, UInt16(1)] }
        let inverses = try batchInverse(linearFactors, mod: g)
        var rows = [[UInt64]](repeating: [UInt64](repeating: 0, count: (n + 63) / 64), count: nk)
        for j in 0..<n {
            let p = inverses[j]
            for coeff in 0..<t {
                let value = coeff < p.count ? p[coeff] : 0
                if value != 0 {
                    for b in 0..<m where (value >> b) & 1 == 1 {
                        setBit(&rows[coeff * m + b], j)
                    }
                }
            }
        }
        return rows
    }

    public static func keygen(seed: Data) throws -> (ek: Data, dk: Data) {
        precondition(seed.count == 32)
        let stream = Array(Keccak.shake256(Data("qwave-mceliece-kg-v1".utf8) + seed, count: 1 << 24))
        var offset = 0
        let g = try sampleGoppaPoly(stream: stream, offset: &offset)
        let L = sampleSupport(stream: stream, offset: &offset, g: g)
        var rows = try syndromeRows(g: g, support: L)

        // RREF with left-to-right pivot scan; each row used at most once.
        var pivots = [Int]()
        var used = [Int]()
        for col in 0..<n {
            var pivotRow: Int?
            for r in 0..<nk where !used.contains(r) {
                if bit(rows[r], col) {
                    pivotRow = r
                    break
                }
            }
            guard let pivot = pivotRow else { continue }
            used.append(pivot)
            pivots.append(col)
            for r in 0..<nk where r != pivot && bit(rows[r], col) {
                for w in 0..<rows[r].count {
                    rows[r][w] ^= rows[pivot][w]
                }
            }
        }
        guard pivots.count == nk else { throw McElieceError.rankDeficient }

        let rref = used.map { rows[$0] }
        let perm = pivots + (0..<n).filter { !pivots.contains($0) }

        // P[r][c] = rref[r] bit at physical column perm[nk + c]
        var ek = Data(capacity: ekSize)
        for r in 0..<nk {
            var rowBits = [Bool](repeating: false, count: k)
            for c in 0..<k {
                rowBits[c] = bit(rref[r], perm[nk + c])
            }
            ek.append(packBits(rowBits))
        }

        // Physical support: S[p] = L[perm[p]] folds the permutation away.
        var dk = Data()
        dk.append(packFieldElements(g))
        dk.append(packFieldElements(perm.map { L[$0] }))
        return (ek, dk)
    }

    // MARK: - Encapsulation

    static func sampleErrors(_ seed: Data) -> Set<Int> {
        let stream = Array(Keccak.shake256(seed, count: 340 + 2 * 8192))
        var errors = Set<Int>()
        var offset = 340
        while errors.count < t {
            let v = Int(readU16(stream, &offset))
            if v < n {
                errors.insert(v)
            }
        }
        return errors
    }

    /// seed: 32 bytes. Returns (ct, ss).
    public static func encapsulate(ek: Data, seed: Data) throws -> (ct: Data, ss: Data) {
        precondition(ek.count == ekSize && seed.count == 32)
        let message = Keccak.shake256(Data("qwave-mceliece-enc-v1".utf8) + seed, count: 340)
        let errors = sampleErrors(Data("qwave-mceliece-enc-v1".utf8) + seed)

        let word = try encryptWord(ek: ek, message: message, errors: errors)
        let ct = packBits((0..<n).map { bit(word, $0) })
        let ss = Keccak.shake256(Data("qwave-mceliece-ss-v1".utf8) + message + ct, count: 32)
        return (ct, ss)
    }

    static func encryptWord(ek: Data, message: Data, errors: Set<Int>?) throws -> [UInt64] {
        var mWords = [UInt64](repeating: 0, count: (k + 63) / 64)
        for i in 0..<k where (message[i >> 3] >> (i & 7)) & 1 == 1 {
            setBit(&mWords, i)
        }

        var parity = [UInt64](repeating: 0, count: (nk + 63) / 64)
        for r in 0..<nk {
            var acc: UInt64 = 0
            let rowStart = r * 340
            for w in 0..<43 {
                var rowWord: UInt64 = 0
                let byteCount = min(8, ek.count - (rowStart + 8 * w))
                for b in 0..<byteCount {
                    rowWord |= UInt64(ek[rowStart + 8 * w + b]) << (8 * b)
                }
                acc ^= rowWord & mWords[w]
            }
            if acc.nonzeroBitCount & 1 == 1 {
                setBit(&parity, r)
            }
        }

        // word = x(768) || m(2720), then TOGGLE the error bits (XOR — a
        // position whose codeword bit is already 1 must flip to 0).
        var word = parity + mWords
        if let errors {
            for p in errors {
                word[p >> 6] ^= 1 << (p & 63)
            }
        }
        return word
    }

    // MARK: - Decapsulation

    static func syndrome(_ g: [UInt16], _ support: [UInt16], word: [UInt64]) throws -> [UInt16] {
        let linearFactors = support.map { [$0, UInt16(1)] }
        let inverses = try batchInverse(linearFactors, mod: g)
        var s: [UInt16] = [0]
        for p in 0..<n where bit(word, p) {
            s = polyAdd(s, inverses[p])
        }
        return try polyMod(s, g)
    }

    /// Solves the key equation sigma' == S*sigma (mod g), deg sigma <= t, as
    /// a linear system over GF(2^12)[x]/(g): unknowns sigma_0..sigma_t and
    /// h_0..h_{t-1} with S*sigma - sigma' - g*h == 0 coefficient-wise.
    static func keyEquationLocator(_ g: [UInt16], _ s: [UInt16]) throws -> [UInt16] {
        let nvars = (t + 1) + t
        let neqs = 2 * t
        var rows = [[UInt16]](repeating: [UInt16](repeating: 0, count: nvars + 1), count: neqs)
        for k in 0..<neqs {
            for j in 0..<t where j <= k && s[j] != 0 {
                let idx = k - j
                if idx <= t {
                    rows[k][idx] ^= s[j]
                }
            }
            if k <= t - 1 && k % 2 == 0 {
                rows[k][k + 1] ^= 1
            }
            for j in 0...(t) where j <= k && g[j] != 0 {
                let idx = k - j
                if idx <= t - 1 {
                    rows[k][t + 1 + idx] ^= g[j]
                }
            }
        }

        var pivots = [Int]()
        var used = Set<Int>()
        for col in 0..<nvars {
            var pivot: Int?
            for r in 0..<neqs where !used.contains(r) && rows[r][col] != 0 {
                pivot = r
                break
            }
            guard let p = pivot else { continue }
            used.insert(p)
            pivots.append(col)
            let inv = try gfInverse(rows[p][col])
            if inv != 1 {
                rows[p] = rows[p].map { gfMul($0, inv) }
            }
            for r in 0..<neqs where r != p && rows[r][col] != 0 {
                let f = rows[r][col]
                for i in 0..<(nvars + 1) {
                    rows[r][i] ^= gfMul(f, rows[p][i])
                }
            }
        }
        let free = (0..<nvars).filter { !pivots.contains($0) }
        guard let firstFree = free.first else { throw McElieceError.decodingFailure }
        var solution = [UInt16](repeating: 0, count: nvars)
        solution[firstFree] = 1
        for col in pivots.reversed() {
            var pivotRow: Int?
            for r in 0..<neqs where rows[r][col] != 0 {
                pivotRow = r
                break
            }
            guard let r = pivotRow else { throw McElieceError.decodingFailure }
            var value = rows[r][nvars]
            for c in 0..<nvars where c != col && rows[r][c] != 0 {
                value ^= gfMul(rows[r][c], solution[c])
            }
            solution[col] = value
        }
        return Array(solution.prefix(t + 1))
    }

    /// Error positions via the key equation sigma' == S*sigma (mod g).
    static func patterson(_ g: [UInt16], _ support: [UInt16], syndrome s: [UInt16]) throws -> Set<Int> {
        guard s != [0] else { return [] }
        let sigma = try keyEquationLocator(g, s)
        var errors = Set<Int>()
        for p in 0..<n {
            if polyEvaluate(sigma, at: support[p]) == 0 {
                errors.insert(p)
            }
        }
        return errors
    }

    public static func decapsulate(dk: Data, ct: Data) throws -> Data {
        precondition(dk.count == dkSize && ct.count == ctSize)
        let g = unpackFieldElements(dk.prefix(98), count: t + 1)
        let support = unpackFieldElements(dk.subdata(in: 98..<dk.count), count: n)

        var word = [UInt64](repeating: 0, count: (n + 63) / 64)
        for p in 0..<n where (ct[p >> 3] >> (p & 7)) & 1 == 1 {
            setBit(&word, p)
        }

        let s = try syndrome(g, support, word: word)
        let errors = try patterson(g, support, syndrome: s)

        // Verification: the corrected word must be a codeword (zero syndrome).
        var corrected = word
        for p in errors {
            corrected[p >> 6] ^= 1 << (p & 63)
        }
        guard try syndrome(g, support, word: corrected) == [0] else {
            throw McElieceError.decodingFailure
        }

        // m = last k bits of the corrected word.
        var message = Data(count: 340)
        for i in 0..<k where bit(corrected, nk + i) {
            message[i >> 3] |= 1 << (i & 7)
        }
        let ss = Keccak.shake256(Data("qwave-mceliece-ss-v1".utf8) + message + ct, count: 32)
        return ss
    }
}
