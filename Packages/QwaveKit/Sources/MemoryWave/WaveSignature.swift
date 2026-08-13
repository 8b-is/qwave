import CryptoKit
import Foundation

/// Eight-harmonic wave fingerprint (MEM8 `WaveSignature`).
///
/// Derivation matches `mem8/src/types.rs`: hash the payload, expand into
/// 8 frequency/phase/amplitude legs, then hash the reconstructed interference
/// so a flipped harmonic fails `verify()`. The Rust crate uses blake3; this
/// Swift port uses SHA-256 with a domain separator so the structure and
/// tamper property are identical without taking a C dependency.
public struct WaveSignature: Equatable, Sendable {
    public var frequencies: [Double]
    public var phases: [Double]
    public var amplitudes: [Double]
    public var interferenceHash: [UInt8]

    public static let harmonicCount = 8

    public init(frequencies: [Double], phases: [Double], amplitudes: [Double], interferenceHash: [UInt8]) {
        self.frequencies = frequencies
        self.phases = phases
        self.amplitudes = amplitudes
        self.interferenceHash = interferenceHash
    }

    public static func fromContent(_ content: Data, identityFrequency: Double) -> WaveSignature {
        var hasher = SHA256()
        hasher.update(data: Data("qwave.memorywave.v1".utf8))
        hasher.update(data: content)
        let digest = hasher.finalize()
        let hash = Array(digest)

        var frequencies = [Double](repeating: 0, count: harmonicCount)
        var phases = [Double](repeating: 0, count: harmonicCount)
        var amplitudes = [Double](repeating: 0, count: harmonicCount)

        for i in 0..<harmonicCount {
            let base = i * 4
            let val = UInt32(hash[base])
                | (UInt32(hash[base + 1]) << 8)
                | (UInt32(hash[base + 2]) << 16)
                | (UInt32(hash[base + 3]) << 24)
            let unit = Double(val) / Double(UInt32.max)
            frequencies[i] = identityFrequency * (1.0 + unit)
            phases[i] = unit * 2.0 * Double.pi
            amplitudes[i] = 0.5 + unit * 0.5
        }

        return WaveSignature(
            frequencies: frequencies,
            phases: phases,
            amplitudes: amplitudes,
            interferenceHash: Array(interferenceDigest(frequencies: frequencies, phases: phases, amplitudes: amplitudes))
        )
    }

    public func verify() -> Bool {
        let calculated = Self.interferenceDigest(
            frequencies: frequencies, phases: phases, amplitudes: amplitudes)
        return calculated.elementsEqual(interferenceHash)
    }

    public var dominantFrequency: Double {
        zip(frequencies, amplitudes).max { lhs, rhs in
            lhs.0 * lhs.1 * lhs.1 < rhs.0 * rhs.1 * rhs.1
        }?.0 ?? frequencies.first ?? 0
    }

    public var energy: Double {
        zip(frequencies, amplitudes).reduce(0) { $0 + $1.0 * $1.1 * $1.1 }
    }

    private static func interferenceDigest(
        frequencies: [Double], phases: [Double], amplitudes: [Double]
    ) -> SHA256.Digest {
        var hasher = SHA256()
        for t in 0..<1000 {
            let time = Double(t) / 1000.0
            var re = 0.0
            var im = 0.0
            for i in 0..<harmonicCount {
                let theta = 2.0 * Double.pi * frequencies[i] * time + phases[i]
                re += amplitudes[i] * cos(theta)
                im += amplitudes[i] * sin(theta)
            }
            var reLE = re.bitPattern.littleEndian
            var imLE = im.bitPattern.littleEndian
            withUnsafeBytes(of: &reLE) { hasher.update(bufferPointer: $0) }
            withUnsafeBytes(of: &imLE) { hasher.update(bufferPointer: $0) }
        }
        return hasher.finalize()
    }
}

public struct EmotionVector: Equatable, Sendable {
    /// -1 (negative) … 1 (positive)
    public var valence: Double
    /// 0 (calm) … 1 (excited)
    public var arousal: Double
    /// 0 (submissive) … 1 (dominant)
    public var dominance: Double

    public init(valence: Double, arousal: Double, dominance: Double) {
        self.valence = valence
        self.arousal = arousal
        self.dominance = dominance
    }

    public static let neutral = EmotionVector(valence: 0, arousal: 0.5, dominance: 0.5)

    public var intensity: Double {
        (valence * valence + arousal * arousal + dominance * dominance).squareRoot()
    }

    public var valenceRational: Rational {
        clampedRational(valence, scale: 1000)
    }

    public var arousalRational: Rational {
        clampedRational(max(0, min(1, arousal)), scale: 1000)
    }

    private func clampedRational(_ value: Double, scale: Int32) -> Rational {
        let clamped = max(-1.0, min(1.0, value))
        return Rational(Int32((clamped * Double(scale)).rounded()), UInt32(scale)) ?? .zero
    }
}
