import Foundation

/// Sealed-vs-shareable boundary, a physical property of the wave (MEM8 WaveInt).
/// Cognitive waves never leave the device. Nexus waves are the only kind that
/// may be offered to a user-chosen inference provider — and even then only
/// as the current prompt, never as stored memory.
public enum WaveProvenance: UInt8, Sendable, Equatable {
    case cognitive = 0x01
    case nexus = 0x02
}

public enum WaveFrameError: Error, Equatable {
    case truncated
    case unsupportedVersion
    case invalidProvenance
    case invalidRational
    case checksumMismatch
}

/// Integer-sovereign wave. Wire/disk image is the 79-byte little-endian frame
/// documented in 8b-Mem8/WAVE_INT.md. Byte 78 is an XOR of the preceding 78
/// bytes so a flipped field cannot enter the grid.
public struct WaveInt: Equatable, Hashable, Sendable {
    public var baseAmplitude: Rational
    public var frequency: Rational
    public var phase: Rational
    public var emotionalValence: Rational
    public var arousal: Rational
    public var createdAt: UInt64
    public var lastAccessed: UInt64
    public var accessCount: UInt32
    public var decayRate: Rational
    public var id: UInt64?
    public var provenance: WaveProvenance

    public static let frameSize = 79

    /// Nanoseconds since the Unix epoch, clamped to 0 for dates before 1970.
    /// `UInt64.init(_: Double)` traps on a negative value, and hand-edited
    /// vault markdown can legitimately carry a `created:` date earlier than
    /// the epoch (e.g. backfilled notes) -- clamp instead of trapping.
    public static func nanosecondsSince1970(_ date: Date) -> UInt64 {
        let seconds = date.timeIntervalSince1970
        guard seconds > 0 else { return 0 }
        let nanos = seconds * 1_000_000_000
        guard nanos < Double(UInt64.max) else { return UInt64.max }
        return UInt64(nanos)
    }

    public init(
        baseAmplitude: Rational,
        frequency: Rational,
        phase: Rational,
        emotionalValence: Rational,
        arousal: Rational,
        createdAt: UInt64,
        lastAccessed: UInt64,
        accessCount: UInt32,
        decayRate: Rational,
        id: UInt64?,
        provenance: WaveProvenance
    ) {
        self.baseAmplitude = baseAmplitude
        self.frequency = frequency
        self.phase = phase
        self.emotionalValence = emotionalValence
        self.arousal = arousal
        self.createdAt = createdAt
        self.lastAccessed = lastAccessed
        self.accessCount = accessCount
        self.decayRate = decayRate
        self.id = id
        self.provenance = provenance
    }

    public func toFrame() -> [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(Self.frameSize)
        bytes.append(MemoryWaveConstants.frameVersion)
        bytes.append(provenance.rawValue)
        bytes.append(contentsOf: Self.rationalBytes(baseAmplitude))
        bytes.append(contentsOf: Self.rationalBytes(frequency))
        bytes.append(contentsOf: Self.rationalBytes(phase))
        bytes.append(contentsOf: Self.rationalBytes(emotionalValence))
        bytes.append(contentsOf: Self.rationalBytes(arousal))
        bytes.append(contentsOf: Self.u64Bytes(createdAt))
        bytes.append(contentsOf: Self.u64Bytes(lastAccessed))
        bytes.append(contentsOf: Self.u32Bytes(accessCount))
        bytes.append(contentsOf: Self.rationalBytes(decayRate))
        bytes.append(contentsOf: Self.u64Bytes(id ?? 0))
        bytes.append(Self.checksum(bytes))
        return bytes
    }

    public static func fromFrame(_ bytes: [UInt8]) -> Result<WaveInt, WaveFrameError> {
        guard bytes.count >= frameSize else { return .failure(.truncated) }
        let version = bytes[0]
        guard version <= MemoryWaveConstants.frameVersion else { return .failure(.unsupportedVersion) }
        guard let provenance = WaveProvenance(rawValue: bytes[1]) else {
            return .failure(.invalidProvenance)
        }
        let body = Array(bytes.prefix(78))
        guard bytes[78] == checksum(body) else { return .failure(.checksumMismatch) }

        func rat(_ offset: Int) -> Rational? {
            let n = Int32(littleEndian: readI32(bytes, offset))
            let d = UInt32(littleEndian: readU32(bytes, offset + 4))
            return Rational(n, d)
        }

        guard
            let amp = rat(2),
            let freq = rat(10),
            let phase = rat(18),
            let valence = rat(26),
            let arousal = rat(34),
            let decay = rat(62)
        else {
            return .failure(.invalidRational)
        }

        let created = UInt64(littleEndian: readU64(bytes, 42))
        let accessed = UInt64(littleEndian: readU64(bytes, 50))
        let count = UInt32(littleEndian: readU32(bytes, 58))
        let rawID = UInt64(littleEndian: readU64(bytes, 70))

        return .success(
            WaveInt(
                baseAmplitude: amp,
                frequency: freq,
                phase: phase,
                emotionalValence: valence,
                arousal: arousal,
                createdAt: created,
                lastAccessed: accessed,
                accessCount: count,
                decayRate: decay,
                id: rawID == 0 ? nil : rawID,
                provenance: provenance
            )
        )
    }

    /// Grid placement: X = frequency vs 0.73 Hz, Y = valence, Z = age in seconds.
    public func coordinate(nowNanos: UInt64? = nil) -> WaveCoord {
        let now = nowNanos ?? createdAt
        let xOffset =
            frequency.log2Q5().flatMap { freqLog in
                MemoryWaveConstants.consciousness.log2Q5().map { freqLog - $0 }
            } ?? 0
        let x = UInt8(clamping: Int(128 + xOffset))
        let yNorm = (emotionalValence.doubleValue + 1.0) / 2.0
        let y = UInt8(clamping: Int((yNorm * 255.0).rounded(.down)))
        let ageSeconds = now >= createdAt ? (now - createdAt) / 1_000_000_000 : 0
        let z = UInt16(clamping: ageSeconds)
        return WaveCoord(x: x, y: y, z: z)
    }

    private static func rationalBytes(_ r: Rational) -> [UInt8] {
        u32Bytes(UInt32(bitPattern: r.num)) + u32Bytes(r.den)
    }

    private static func u32Bytes(_ value: UInt32) -> [UInt8] {
        var le = value.littleEndian
        return withUnsafeBytes(of: &le) { Array($0) }
    }

    private static func u64Bytes(_ value: UInt64) -> [UInt8] {
        var le = value.littleEndian
        return withUnsafeBytes(of: &le) { Array($0) }
    }

    private static func checksum(_ bytes: [UInt8]) -> UInt8 {
        bytes.reduce(0 as UInt8, ^)
    }

    private static func readI32(_ bytes: [UInt8], _ offset: Int) -> Int32 {
        Int32(bitPattern: readU32(bytes, offset))
    }

    private static func readU32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<4 {
            value |= UInt32(bytes[offset + i]) << (8 * i)
        }
        return value
    }

    private static func readU64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 {
            value |= UInt64(bytes[offset + i]) << (8 * i)
        }
        return value
    }
}

/// 3D coordinate in the 256×256×65536 cognitive grid.
public struct WaveCoord: Hashable, Sendable, Equatable {
    public var x: UInt8
    public var y: UInt8
    public var z: UInt16

    public init(x: UInt8, y: UInt8, z: UInt16) {
        self.x = x
        self.y = y
        self.z = z
    }
}

public struct WaveBounds: Sendable, Equatable {
    public var minX: UInt8
    public var minY: UInt8
    public var maxX: UInt8
    public var maxY: UInt8

    public init(minX: UInt8, minY: UInt8, maxX: UInt8, maxY: UInt8) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    public func contains(_ coord: WaveCoord) -> Bool {
        coord.x >= minX && coord.x <= maxX && coord.y >= minY && coord.y <= maxY
    }

    public static func around(_ coord: WaveCoord, radius: UInt8) -> WaveBounds {
        WaveBounds(
            minX: coord.x &- min(coord.x, radius),
            minY: coord.y &- min(coord.y, radius),
            maxX: coord.x &+ min(UInt8.max &- coord.x, radius),
            maxY: coord.y &+ min(UInt8.max &- coord.y, radius)
        )
    }
}
