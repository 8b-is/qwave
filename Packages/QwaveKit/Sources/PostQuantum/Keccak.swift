import Foundation

/// Pure-Swift Keccak-f[1600] sponge: SHA3-224/256/384/512 and SHAKE128/256.
///
/// No CommonCrypto exposure of SHA3 exists on Apple platforms, and the
/// post-quantum KEMs below need SHAKE as an XOF, so the permutation is
/// implemented directly (FIPS 202). Verified against NIST vectors in
/// `PostQuantumTests`.
public enum Keccak {
    private static let roundConstants: [UInt64] = [
        0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
        0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
        0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
        0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
        0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
        0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
    ]

    /// Rotation offsets indexed by x + 5y (FIPS 202 Table 2).
    private static let rhoOffsets: [Int] = [
        0, 1, 62, 28, 27, 36, 44, 6, 55, 20, 3, 10, 43, 25, 39, 41, 45, 15, 21, 8, 18, 2, 61, 56, 14,
    ]

    private static func rotl(_ x: UInt64, _ n: Int) -> UInt64 {
        (x << n) | (x >> (64 - n))
    }

    /// Keccak-f[1600] on a 25-lane state (index = x + 5y).
    static func permute(_ state: inout [UInt64]) {
        precondition(state.count == 25)
        var b = [UInt64](repeating: 0, count: 25)
        for round in 0..<24 {
            // theta
            var c = [UInt64](repeating: 0, count: 5)
            for x in 0..<5 {
                c[x] = state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20]
            }
            var d = [UInt64](repeating: 0, count: 5)
            for x in 0..<5 {
                d[x] = c[(x + 4) % 5] ^ rotl(c[(x + 1) % 5], 1)
            }
            for i in 0..<25 {
                state[i] ^= d[i % 5]
            }
            // rho + pi: b[y + 5*(2x+3y mod 5)] = rotl(A[x][y], rho[x + 5y])
            for x in 0..<5 {
                for y in 0..<5 {
                    b[y + 5 * ((2 * x + 3 * y) % 5)] = rotl(state[x + 5 * y], rhoOffsets[x + 5 * y])
                }
            }
            // chi
            for x in 0..<5 {
                for y in 0..<5 {
                    state[x + 5 * y] = b[x + 5 * y] ^ ((~b[(x + 1) % 5 + 5 * y]) & b[(x + 2) % 5 + 5 * y])
                }
            }
            // iota
            state[0] ^= roundConstants[round]
        }
    }

    // MARK: - Sponge

    private enum Domain {
        /// FIPS 202 domain byte for a hash function (0x06).
        case hash
        /// FIPS 202 domain byte for an extendable-output function (0x1F).
        case xof
    }

    /// Absorb phase: returns the state with the whole (padded) input absorbed,
    /// ready to squeeze from.
    private static func absorbed(_ input: Data, rate: Int, domain: Domain) -> [UInt64] {
        var state = [UInt64](repeating: 0, count: 25)
        var buffer = [UInt8](repeating: 0, count: rate)

        func absorb() {
            for i in 0..<rate {
                state[i / 8] ^= UInt64(buffer[i]) << (8 * (i % 8))
            }
            permute(&state)
        }

        // Absorb full rate-sized blocks.
        var offset = 0
        while input.count - offset >= rate {
            input.copyBytes(to: &buffer, from: offset..<(offset + rate))
            absorb()
            offset += rate
        }

        // Final block: multirate padding (always at least one padded block,
        // even for empty input or input that landed on a rate boundary).
        let remaining = input.count - offset
        buffer = [UInt8](repeating: 0, count: rate)
        if remaining > 0 {
            input.copyBytes(to: &buffer, from: offset..<input.count)
        }
        buffer[remaining] = domain == .hash ? 0x06 : 0x1F
        buffer[rate - 1] ^= 0x80
        absorb()
        return state
    }

    /// Extract one rate-sized block from the current state.
    private static func squeezeBlock(_ state: [UInt64], rate: Int) -> [UInt8] {
        var block = [UInt8](repeating: 0, count: rate)
        for i in 0..<rate {
            block[i] = UInt8((state[i / 8] >> (8 * (i % 8))) & 0xFF)
        }
        return block
    }

    private static func sponge(_ input: Data, rate: Int, domain: Domain, outputLength: Int) -> Data {
        var state = absorbed(input, rate: rate, domain: domain)

        var output = Data()
        while output.count < outputLength {
            let block = squeezeBlock(state, rate: rate)
            let needed = min(rate, outputLength - output.count)
            output.append(contentsOf: block.prefix(needed))
            if output.count < outputLength {
                permute(&state)
            }
        }
        return output
    }

    // MARK: - Incremental XOF

    /// Incremental SHAKE128 squeeze.
    ///
    /// FIPS 203's SampleNTT (Algorithm 7) performs rejection sampling and so
    /// consumes an *unbounded* number of XOF bytes — the one-shot
    /// `shake128(_:count:)` cannot express that without picking an arbitrary
    /// cut-off, and picking one silently biases the sampled matrix.
    ///
    /// Not thread-safe by construction: it is a value type holding sponge
    /// state, so each sampling loop owns its own reader.
    public struct SHAKE128Reader {
        private static let rate = 168

        private var state: [UInt64]
        private var block: [UInt8]
        private var offset: Int

        public init(_ input: Data) {
            state = Keccak.absorbed(input, rate: Self.rate, domain: .xof)
            block = Keccak.squeezeBlock(state, rate: Self.rate)
            offset = 0
        }

        /// Next `count` bytes of the XOF stream, permuting as often as needed.
        public mutating func read(_ count: Int) -> [UInt8] {
            var out = [UInt8]()
            out.reserveCapacity(count)
            while out.count < count {
                if offset == Self.rate {
                    Keccak.permute(&state)
                    block = Keccak.squeezeBlock(state, rate: Self.rate)
                    offset = 0
                }
                let take = min(Self.rate - offset, count - out.count)
                out.append(contentsOf: block[offset..<(offset + take)])
                offset += take
            }
            return out
        }
    }

    // MARK: - Public API

    /// SHA3-256 (FIPS 202).
    public static func sha3_256(_ data: Data) -> Data {
        sponge(data, rate: 136, domain: .hash, outputLength: 32)
    }

    /// SHA3-512.
    public static func sha3_512(_ data: Data) -> Data {
        sponge(data, rate: 72, domain: .hash, outputLength: 64)
    }

    /// SHA3-384.
    public static func sha3_384(_ data: Data) -> Data {
        sponge(data, rate: 104, domain: .hash, outputLength: 48)
    }

    /// SHA3-224.
    public static func sha3_224(_ data: Data) -> Data {
        sponge(data, rate: 144, domain: .hash, outputLength: 28)
    }

    /// SHAKE128 XOF.
    public static func shake128(_ data: Data, count: Int) -> Data {
        sponge(data, rate: 168, domain: .xof, outputLength: count)
    }

    /// SHAKE256 XOF.
    public static func shake256(_ data: Data, count: Int) -> Data {
        sponge(data, rate: 136, domain: .xof, outputLength: count)
    }
}
