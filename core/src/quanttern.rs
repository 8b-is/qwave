//! QuantTern — the emotional ternary code, the qUltraKotoro wire.
//!
//! The VAD model of emotion (Valence · Arousal · Dominance, each −1…+1) is
//! quantized to a **ternary** vector `{-1, 0, +1}` and packed four trits per
//! byte — the same 1.58-bit idea BitNet b1.58 uses for weights, applied to
//! feeling instead of parameters. The result is a tiny, honest fingerprint of
//! affect: cheap to store, cheap to compare, and it cannot lie about *how much*
//! it is sure — a `zero` is a real "don't know".
//!
//! This is the exact port of `qUltraKotoro/Sources/QuantTern/QuantTern.swift`.
//! It re-uses the *gate* codec (`−1→0b00 · 0→0b01 · +1→0b10`), the same one
//! `crush-love-dev/pureQTern.rs` runs — not the weight codec of `ternary-lane`.
//!
//! The wire into Qwave: `EmotionCode::wave_fields` projects the code onto the
//! `(valence, arousal)` the [`crate::wave::WaveInt`] substrate already carries
//! as [`Rational`] integers, so a feeling can ride the MEM8 grid.

use crate::Rational;

/// Default ternary threshold. Below this the value reads as a genuine `0`.
pub const DEFAULT_THRESHOLD: f32 = 0.33;

/// One ternary trit of the emotional code.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[repr(i8)]
pub enum Trit {
    Minus = -1,
    Zero = 0,
    Plus = 1,
}

impl Trit {
    /// Quantize one axis to a trit. Below `threshold` (in magnitude) it is a
    /// genuine "don't know" — a real zero, not a rounding error.
    pub fn from_f32(x: f32, threshold: f32) -> Self {
        if x >= threshold {
            Trit::Plus
        } else if x <= -threshold {
            Trit::Minus
        } else {
            Trit::Zero
        }
    }

    pub fn raw(self) -> i8 {
        self as i8
    }

    pub fn from_raw(raw: i8) -> Option<Self> {
        match raw {
            -1 => Some(Trit::Minus),
            0 => Some(Trit::Zero),
            1 => Some(Trit::Plus),
            _ => None,
        }
    }

    /// The two-bit gate code: `−1→0b00 · 0→0b01 · +1→0b10` (0b11 is never
    /// written — the strict gate refuses).
    pub fn code(self) -> u8 {
        ((self as i8 + 1) as u8) & 0b11
    }

    pub fn from_code(code: u8) -> Self {
        match code & 0b11 {
            0b00 => Trit::Minus,
            0b01 => Trit::Zero,
            0b10 => Trit::Plus,
            _ => Trit::Zero, // reserved → rest
        }
    }
}

/// Valence · Arousal · Dominance, each clamped to −1…+1.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Vad {
    pub valence: f32,
    pub arousal: f32,
    pub dominance: f32,
}

impl Vad {
    pub fn new(valence: f32, arousal: f32, dominance: f32) -> Self {
        Self {
            valence: clamp1(valence),
            arousal: clamp1(arousal),
            dominance: clamp1(dominance),
        }
    }

    pub const NEUTRAL: Vad = Vad {
        valence: 0.0,
        arousal: 0.0,
        dominance: 0.0,
    };

    /// The three trits of the model, thresholded.
    pub fn trits(&self, threshold: f32) -> [Trit; 3] {
        [
            Trit::from_f32(self.valence, threshold),
            Trit::from_f32(self.arousal, threshold),
            Trit::from_f32(self.dominance, threshold),
        ]
    }
}

/// A packed emotional code: the trits, the bytes, and a printable `qt:` hex tag.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EmotionCode {
    pub trits: Vec<Trit>,
    pub bytes: Vec<u8>,
    pub hex: String,
}

impl EmotionCode {
    /// How many trits are non-neutral — the "signal" in the fingerprint.
    pub fn magnitude(&self) -> usize {
        self.trits.iter().filter(|t| **t != Trit::Zero).count()
    }

    pub fn is_neutral(&self) -> bool {
        self.magnitude() == 0
    }

    /// The wire into the MEM8 substrate: the `(valence, arousal)` the
    /// `WaveInt` frame carries, as reduced integers. Dominance has no wave
    /// field and stays in the code.
    pub fn wave_fields(&self) -> (Rational, Rational) {
        let v = self.trits.first().copied().unwrap_or(Trit::Zero);
        let a = self.trits.get(1).copied().unwrap_or(Trit::Zero);
        (
            Rational::integer(v.raw() as i32),
            Rational::integer(a.raw() as i32),
        )
    }
}

/// Encode a VAD reading into an emotional code.
pub fn encode(vad: Vad, threshold: f32) -> EmotionCode {
    pack(&vad.trits(threshold))
}

/// Pack trits four-per-byte, LSB first, and compute the `qt:` tag.
pub fn pack(trits: &[Trit]) -> EmotionCode {
    let mut bytes: Vec<u8> = Vec::with_capacity(trits.len().div_ceil(4));
    let mut i = 0;
    while i < trits.len() {
        let mut b: u8 = 0;
        for j in 0..4 {
            let t = trits.get(i + j).copied().unwrap_or(Trit::Zero);
            b |= t.code() << (2 * j as u8);
        }
        bytes.push(b);
        i += 4;
    }
    let mut hex = String::from("qt:");
    for b in &bytes {
        hex.push_str(&format!("{b:02x}"));
    }
    EmotionCode {
        trits: trits.to_vec(),
        bytes,
        hex,
    }
}

/// Unpack `count` trits out of the packed byte stream.
pub fn unpack(bytes: &[u8], count: usize) -> Vec<Trit> {
    let mut trits: Vec<Trit> = Vec::with_capacity(bytes.len() * 4);
    for b in bytes {
        for j in 0..4u8 {
            trits.push(Trit::from_code((b >> (2 * j)) & 0b11));
        }
    }
    trits.truncate(count);
    trits
}

/// Cosine-style agreement in `0…1`: how alike two emotional codes are.
pub fn agreement(a: &[Trit], b: &[Trit]) -> f32 {
    let n = a.len().min(b.len());
    if n == 0 {
        return 1.0;
    }
    let hit = (0..n).filter(|&i| a[i] == b[i]).count();
    hit as f32 / n as f32
}

fn clamp1(x: f32) -> f32 {
    x.max(-1.0).min(1.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_gate_codec_round_trips() {
        for t in [Trit::Minus, Trit::Zero, Trit::Plus] {
            assert_eq!(Trit::from_code(t.code()), t);
        }
        // +1 → 0b10, and 0b11 (reserved) reads as rest.
        assert_eq!(Trit::Plus.code(), 0b10);
        assert_eq!(Trit::from_code(0b11), Trit::Zero);
    }

    #[test]
    fn pack_unpack_is_the_identity_on_ternary() {
        let trits = vec![
            Trit::Plus,
            Trit::Minus,
            Trit::Zero,
            Trit::Plus,
            Trit::Zero,
            Trit::Zero,
            Trit::Minus,
            Trit::Plus,
        ];
        let code = pack(&trits);
        assert_eq!(code.bytes.len(), 2, "eight trits pack into two bytes");
        assert_eq!(unpack(&code.bytes, trits.len()), trits);
    }

    #[test]
    fn the_threshold_makes_a_real_zero() {
        // 0.30 is below the default 0.33 — a genuine "don't know".
        assert_eq!(Trit::from_f32(0.30, DEFAULT_THRESHOLD), Trit::Zero);
        assert_eq!(Trit::from_f32(-0.30, DEFAULT_THRESHOLD), Trit::Zero);
        assert_eq!(Trit::from_f32(0.62, DEFAULT_THRESHOLD), Trit::Plus);
        assert_eq!(Trit::from_f32(-0.41, DEFAULT_THRESHOLD), Trit::Minus);
    }

    #[test]
    fn a_reading_encodes_to_its_hex_tag() {
        let vad = Vad::new(0.62, -0.41, 0.10);
        let code = encode(vad, DEFAULT_THRESHOLD);
        assert_eq!(code.trits, vec![Trit::Plus, Trit::Minus, Trit::Zero]);
        assert_eq!(code.hex, "qt:52");
        assert_eq!(code.magnitude(), 2);
        assert!(!code.is_neutral());
        assert!(
            Vad::NEUTRAL
                .trits(DEFAULT_THRESHOLD)
                .iter()
                .all(|t| *t == Trit::Zero)
        );
    }

    #[test]
    fn the_wave_bridge_maps_feeling_to_the_mem8_fields() {
        let code = encode(Vad::new(0.9, -0.9, 0.0), DEFAULT_THRESHOLD);
        let (valence, arousal) = code.wave_fields();
        assert_eq!(valence, Rational::integer(1));
        assert_eq!(arousal, Rational::integer(-1));
    }

    #[test]
    fn agreement_is_the_shared_fraction() {
        let a = [Trit::Plus, Trit::Minus, Trit::Zero];
        let b = [Trit::Plus, Trit::Zero, Trit::Zero];
        assert_eq!(agreement(&a, &a), 1.0);
        assert!((agreement(&a, &b) - 2.0 / 3.0).abs() < 1e-6);
        assert_eq!(agreement(&[], &[]), 1.0);
    }
}
