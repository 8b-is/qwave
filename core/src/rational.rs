//! Reduced signed rational — the number type of the MEM8 integer substrate.

/// Reduced signed rational used by the MEM8 integer substrate.
/// A denominator of zero is unrepresentable: hostile frames cannot poison
/// equality or hashing.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Rational {
    pub num: i32,
    pub den: u32,
}

impl Rational {
    /// Reduced construction; `None` when `den == 0`.
    pub fn new(num: i32, den: u32) -> Option<Self> {
        if den == 0 {
            return None;
        }
        let g = gcd((num as i64).unsigned_abs() as u32, den);
        Some(Self {
            num: num / g as i32,
            den: den / g,
        })
    }

    pub const fn integer(value: i32) -> Self {
        Self { num: value, den: 1 }
    }

    pub const ZERO: Self = Self::integer(0);
    pub const ONE: Self = Self::integer(1);

    pub fn double_value(self) -> f64 {
        self.num as f64 / self.den as f64
    }

    /// Checked addition, reducing the result.
    pub fn adding(self, other: Self) -> Option<Self> {
        let a = self.num as i64 * other.den as i64;
        let b = other.num as i64 * self.den as i64;
        let d = self.den as i64 * other.den as i64;
        let sum = a.checked_add(b)?;
        if !(i32::MIN as i64..=i32::MAX as i64).contains(&sum) || d <= 0 || d > u32::MAX as i64 {
            return None;
        }
        Self::new(sum as i32, d as u32)
    }

    /// Checked multiplication, reducing the result.
    pub fn multiplying(self, other: Self) -> Option<Self> {
        let n = self.num as i64 * other.num as i64;
        let d = self.den as i64 * other.den as i64;
        if !(i32::MIN as i64..=i32::MAX as i64).contains(&n) || d <= 0 || d > u32::MAX as i64 {
            return None;
        }
        Self::new(n as i32, d as u32)
    }

    /// `floor(log2(|self|) * 32)` — 5 fractional bits, matching MEM8
    /// `log2_q5_rational`. `None` for zero.
    pub fn log2_q5(self) -> Option<i32> {
        if self.num == 0 {
            return None;
        }
        Some(log2_q5_u64((self.num as i64).unsigned_abs()) - log2_q5_u64(u64::from(self.den)))
    }
}

fn gcd(mut a: u32, mut b: u32) -> u32 {
    while b != 0 {
        let t = a % b;
        a = b;
        b = t;
    }
    if a == 0 { 1 } else { a }
}

fn log2_q5_u64(n: u64) -> i32 {
    let lz = n.leading_zeros() as i32;
    let int_bits = 63 - lz;
    let shift = 64 - lz - 1 - 5;
    let frac: i32 = if shift >= 0 {
        ((n >> shift) & 0x1F) as i32
    } else {
        ((n << (-shift)) & 0x1F) as i32
    };
    int_bits * 32 + frac
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zero_denominator_is_unrepresentable() {
        assert!(Rational::new(1, 0).is_none());
    }

    #[test]
    fn construction_reduces() {
        let r = Rational::new(2, 4).unwrap();
        assert_eq!(r, Rational::new(1, 2).unwrap());
        let neg = Rational::new(-3, 9).unwrap();
        assert_eq!((neg.num, neg.den), (-1, 3));
    }

    #[test]
    fn arithmetic_matches_swift_semantics() {
        let a = Rational::new(1, 2).unwrap();
        let b = Rational::new(1, 3).unwrap();
        assert_eq!(a.adding(b).unwrap(), Rational::new(5, 6).unwrap());
        assert_eq!(a.multiplying(b).unwrap(), Rational::new(1, 6).unwrap());
    }

    #[test]
    fn log2_q5_zero_is_nil() {
        assert!(Rational::ZERO.log2_q5().is_none());
    }

    #[test]
    fn log2_q5_matches_the_swift_reference_values() {
        // 73/100 is the consciousness gate (0.73 Hz).
        let c = Rational::new(73, 100).unwrap();
        // Swift: log2Q5(73) - log2Q5(100) = 196 - 210 = -14 (5 fractional bits).
        assert_eq!(c.log2_q5(), Some(-14));
        // 1.0 → 0
        assert_eq!(Rational::ONE.log2_q5(), Some(0));
        // 2.0 → 32
        assert_eq!(Rational::new(2, 1).unwrap().log2_q5(), Some(32));
    }
}
