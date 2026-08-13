import Foundation

/// Constants shared with the MEM8 cognitive substrate (8b-Mem8 / mem8-core).
public enum MemoryWaveConstants {
    /// Consciousness-gate resonance (0.73 Hz).
    public static let consciousness = Rational(73, 100)!
    /// Golden-ratio identity frequency multiplier.
    public static let goldenRatio = Rational(1618, 1000)!
    /// Sparse grid extents: 256 × 256 × 65536.
    public static let gridX: UInt8 = 255
    public static let gridY: UInt8 = 255
    public static let gridZ: UInt16 = 65535
    /// Wave-frame version written by this module.
    public static let frameVersion: UInt8 = 1
    /// Maximum page extract forwarded to any inference provider.
    public static let maxPageCharacters = 12_000
    public static let maxPromptCharacters = 4_000
    public static let maxBodyCharacters = 8_000
}
