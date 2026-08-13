import Foundation

/// Reduced signed rational used by the MEM8 integer substrate.
/// Denominator of 0 is unrepresentable — hostile frames cannot poison Eq/Hash.
public struct Rational: Hashable, Sendable, Comparable {
    public let num: Int32
    public let den: UInt32

    public init?(_ num: Int32, _ den: UInt32) {
        guard den != 0 else { return nil }
        let g = Self.gcd(UInt32(abs(Int64(num))), den)
        self.num = num / Int32(g)
        self.den = den / g
    }

    public init(integer: Int32) {
        self.num = integer
        self.den = 1
    }

    public static let zero = Rational(integer: 0)
    public static let one = Rational(integer: 1)

    public var doubleValue: Double { Double(num) / Double(den) }

    public static func < (lhs: Rational, rhs: Rational) -> Bool {
        Int64(lhs.num) * Int64(rhs.den) < Int64(rhs.num) * Int64(lhs.den)
    }

    public func adding(_ other: Rational) -> Rational? {
        let a = Int64(num) * Int64(other.den)
        let b = Int64(other.num) * Int64(den)
        let d = Int64(den) * Int64(other.den)
        guard let sum = a.checkedAdd(b), d > 0, d <= Int64(UInt32.max) else { return nil }
        guard sum >= Int64(Int32.min), sum <= Int64(Int32.max) else { return nil }
        return Rational(Int32(sum), UInt32(d))
    }

    public func multiplying(_ other: Rational) -> Rational? {
        let n = Int64(num) * Int64(other.num)
        let d = Int64(den) * Int64(other.den)
        guard n >= Int64(Int32.min), n <= Int64(Int32.max), d > 0, d <= Int64(UInt32.max) else {
            return nil
        }
        return Rational(Int32(n), UInt32(d))
    }

    /// floor(log2(|self|) * 32) — 5 fractional bits, matching MEM8 `log2_q5_rational`.
    public func log2Q5() -> Int32? {
        guard num != 0 else { return nil }
        return Self.log2Q5(UInt64(abs(Int64(num)))) - Self.log2Q5(UInt64(den))
    }

    private static func log2Q5(_ n: UInt64) -> Int32 {
        let lz = n.leadingZeroBitCount
        let intBits = Int32(63 - lz)
        let shift = 64 - lz - 1 - 5
        let frac: Int32
        if shift >= 0 {
            frac = Int32((n >> shift) & 0x1F)
        } else {
            frac = Int32((n << -shift) & 0x1F)
        }
        return intBits * 32 + frac
    }

    private static func gcd(_ a: UInt32, _ b: UInt32) -> UInt32 {
        var x = a
        var y = b
        while y != 0 {
            let t = x % y
            x = y
            y = t
        }
        return x == 0 ? 1 : x
    }
}

private extension Int64 {
    func checkedAdd(_ other: Int64) -> Int64? {
        let (result, overflow) = addingReportingOverflow(other)
        return overflow ? nil : result
    }
}
