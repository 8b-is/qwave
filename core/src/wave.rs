//! The MEM8 wave substrate — the 79-byte `WaveInt` frame.
//!
//! Wire/disk image is the little-endian frame documented in
//! `8b-Mem8/WAVE_INT.md`. Byte 78 is an XOR of the preceding 78 bytes so a
//! flipped field cannot enter the grid. This module is the exact port of the
//! Swift `MemoryWave.WaveInt`; the tests pin the same vectors.

use crate::Rational;

/// Frame size in bytes: 1 version + 1 provenance + 6 rationals (8 B each) +
/// 2×u64 + u32 + u64 + 1 checksum.
pub const FRAME_SIZE: usize = 79;

/// The frame version this module writes.
pub const FRAME_VERSION: u8 = 1;

/// Consciousness-gate resonance (0.73 Hz).
pub fn consciousness() -> Rational {
    Rational::new(73, 100).expect("73/100 is always valid")
}

/// Sealed-vs-shareable boundary. Cognitive waves never leave the device;
/// nexus waves are the only kind that may be offered to a user-chosen
/// inference provider.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum WaveProvenance {
    Cognitive = 0x01,
    Nexus = 0x02,
}

impl WaveProvenance {
    pub fn from_raw(raw: u8) -> Option<Self> {
        match raw {
            0x01 => Some(Self::Cognitive),
            0x02 => Some(Self::Nexus),
            _ => None,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WaveFrameError {
    Truncated,
    UnsupportedVersion,
    InvalidProvenance,
    InvalidRational,
    ChecksumMismatch,
}

/// Integer-sovereign wave, 79-byte wire image.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct WaveInt {
    pub base_amplitude: Rational,
    pub frequency: Rational,
    pub phase: Rational,
    pub emotional_valence: Rational,
    pub arousal: Rational,
    pub created_at: u64,
    pub last_accessed: u64,
    pub access_count: u32,
    pub decay_rate: Rational,
    pub id: Option<u64>,
    pub provenance: WaveProvenance,
}

impl WaveInt {
    /// Serialize to the 79-byte little-endian frame.
    pub fn to_frame(self) -> [u8; FRAME_SIZE] {
        let mut bytes = [0u8; FRAME_SIZE];
        bytes[0] = FRAME_VERSION;
        bytes[1] = self.provenance as u8;
        put_rational(&mut bytes, 2, self.base_amplitude);
        put_rational(&mut bytes, 10, self.frequency);
        put_rational(&mut bytes, 18, self.phase);
        put_rational(&mut bytes, 26, self.emotional_valence);
        put_rational(&mut bytes, 34, self.arousal);
        bytes[42..50].copy_from_slice(&self.created_at.to_le_bytes());
        bytes[50..58].copy_from_slice(&self.last_accessed.to_le_bytes());
        bytes[58..62].copy_from_slice(&self.access_count.to_le_bytes());
        put_rational(&mut bytes, 62, self.decay_rate);
        bytes[70..78].copy_from_slice(&self.id.unwrap_or(0).to_le_bytes());
        bytes[78] = checksum(&bytes[..78]);
        bytes
    }

    /// Parse the 79-byte frame. Rejects truncation, unknown versions,
    /// hostile provenance, unrepresentable rationals, and checksum flips.
    pub fn from_frame(bytes: &[u8]) -> Result<Self, WaveFrameError> {
        if bytes.len() < FRAME_SIZE {
            return Err(WaveFrameError::Truncated);
        }
        if bytes[0] > FRAME_VERSION {
            return Err(WaveFrameError::UnsupportedVersion);
        }
        let provenance =
            WaveProvenance::from_raw(bytes[1]).ok_or(WaveFrameError::InvalidProvenance)?;
        if bytes[78] != checksum(&bytes[..78]) {
            return Err(WaveFrameError::ChecksumMismatch);
        }
        let rat = |offset: usize| -> Result<Rational, WaveFrameError> {
            let num = i32::from_le_bytes(bytes[offset..offset + 4].try_into().unwrap());
            let den = u32::from_le_bytes(bytes[offset + 4..offset + 8].try_into().unwrap());
            Rational::new(num, den).ok_or(WaveFrameError::InvalidRational)
        };
        let created_at = u64::from_le_bytes(bytes[42..50].try_into().unwrap());
        let last_accessed = u64::from_le_bytes(bytes[50..58].try_into().unwrap());
        let access_count = u32::from_le_bytes(bytes[58..62].try_into().unwrap());
        let raw_id = u64::from_le_bytes(bytes[70..78].try_into().unwrap());
        Ok(Self {
            base_amplitude: rat(2)?,
            frequency: rat(10)?,
            phase: rat(18)?,
            emotional_valence: rat(26)?,
            arousal: rat(34)?,
            created_at,
            last_accessed,
            access_count,
            decay_rate: rat(62)?,
            id: if raw_id == 0 { None } else { Some(raw_id) },
            provenance,
        })
    }

    /// Grid placement: X = frequency vs 0.73 Hz, Y = valence, Z = age in
    /// seconds (clamped to u16). Ported exactly from the Swift coordinate.
    pub fn coordinate(self, now_nanos: Option<u64>) -> (u8, u8, u16) {
        let now = now_nanos.unwrap_or(self.created_at);
        let x_offset = match (self.frequency.log2_q5(), consciousness().log2_q5()) {
            (Some(freq_log), Some(con_log)) => freq_log - con_log,
            _ => 0,
        };
        let x = (128i32 + x_offset).clamp(0, 255) as u8;
        let y_norm = (self.emotional_valence.double_value() + 1.0) / 2.0;
        let y = ((y_norm * 255.0).floor() as i32).clamp(0, 255) as u8;
        let age_seconds = if now >= self.created_at {
            (now - self.created_at) / 1_000_000_000
        } else {
            0
        };
        let z = age_seconds.clamp(0, u16::MAX as u64) as u16;
        (x, y, z)
    }
}

fn put_rational(bytes: &mut [u8; FRAME_SIZE], offset: usize, r: Rational) {
    bytes[offset..offset + 4].copy_from_slice(&r.num.to_le_bytes());
    bytes[offset + 4..offset + 8].copy_from_slice(&r.den.to_le_bytes());
}

/// XOR of all bytes — the frame's integrity seal.
///
/// Wild trick: the fold runs over `u64` chunks (8 bytes per XOR instead of
/// 1), then the tail byte-by-byte — the 78-byte body costs 10 XORs instead
/// of 78.
pub fn checksum(bytes: &[u8]) -> u8 {
    let (chunks, tail) = bytes.split_at(bytes.len() - bytes.len() % 8);
    let mut acc = 0u64;
    for chunk in chunks.chunks_exact(8) {
        acc ^= u64::from_le_bytes(chunk.try_into().unwrap());
    }
    let mut out = (acc ^ (acc >> 32) ^ (acc >> 16) ^ (acc >> 8) ^ acc) as u8;
    for b in tail {
        out ^= b;
    }
    out
}

/// C ABI: validate a 79-byte frame. 0 = valid; 1..5 = the WaveFrameError
/// discriminant + 1. Never dereferences a null pointer: a null frame is
/// Truncated (1).
///
/// # Safety
/// `frame` must point to 79 readable bytes, or be null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn qw_wave_frame_validate(frame: *const u8) -> u32 {
    if frame.is_null() {
        return 1;
    }
    // SAFETY: caller contract — 79 readable bytes.
    let bytes = unsafe { core::slice::from_raw_parts(frame, FRAME_SIZE) };
    match WaveInt::from_frame(bytes) {
        Ok(_) => 0,
        Err(WaveFrameError::Truncated) => 1,
        Err(WaveFrameError::UnsupportedVersion) => 2,
        Err(WaveFrameError::InvalidProvenance) => 3,
        Err(WaveFrameError::InvalidRational) => 4,
        Err(WaveFrameError::ChecksumMismatch) => 5,
    }
}

/// C ABI: the grid coordinate of a valid frame at `now_nanos`. Callers must
/// validate first; an invalid frame yields the origin (0, 0, 0).
///
/// # Safety
/// `frame` must point to 79 readable bytes, or be null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn qw_wave_frame_coord(
    frame: *const u8,
    now_nanos: u64,
    x: *mut u8,
    y: *mut u8,
    z: *mut u16,
) {
    if frame.is_null() || x.is_null() || y.is_null() || z.is_null() {
        return;
    }
    // SAFETY: caller contract — readable frame, writable out-pointers.
    let bytes = unsafe { core::slice::from_raw_parts(frame, FRAME_SIZE) };
    let (cx, cy, cz) = match WaveInt::from_frame(bytes) {
        Ok(wave) => wave.coordinate(Some(now_nanos)),
        Err(_) => (0, 0, 0),
    };
    unsafe {
        *x = cx;
        *y = cy;
        *z = cz;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> WaveInt {
        WaveInt {
            base_amplitude: Rational::new(1, 2).unwrap(),
            frequency: Rational::new(73, 100).unwrap(),
            phase: Rational::new(1, 4).unwrap(),
            emotional_valence: Rational::new(-1, 2).unwrap(),
            arousal: Rational::new(3, 10).unwrap(),
            created_at: 1_700_000_000_000_000_000,
            last_accessed: 1_700_000_000_000_000_001,
            access_count: 7,
            decay_rate: Rational::new(1, 10).unwrap(),
            id: Some(42),
            provenance: WaveProvenance::Cognitive,
        }
    }

    #[test]
    fn round_trips_exactly() {
        let frame = sample().to_frame();
        assert_eq!(frame.len(), 79);
        assert_eq!(WaveInt::from_frame(&frame).unwrap(), sample());
    }

    #[test]
    fn rejects_unknown_provenance() {
        let mut frame = sample().to_frame();
        frame[1] = 0xFF;
        frame[78] = checksum(&frame[..78]);
        assert_eq!(
            WaveInt::from_frame(&frame),
            Err(WaveFrameError::InvalidProvenance)
        );
    }

    #[test]
    fn checksum_catches_a_flip() {
        let mut frame = sample().to_frame();
        frame[10] ^= 0x01;
        assert_eq!(
            WaveInt::from_frame(&frame),
            Err(WaveFrameError::ChecksumMismatch)
        );
    }

    #[test]
    fn truncated_frames_are_rejected() {
        let frame = sample().to_frame();
        assert_eq!(
            WaveInt::from_frame(&frame[..40]),
            Err(WaveFrameError::Truncated)
        );
    }

    #[test]
    fn future_versions_are_rejected() {
        let mut frame = sample().to_frame();
        frame[0] = FRAME_VERSION + 1;
        frame[78] = checksum(&frame[..78]);
        assert_eq!(
            WaveInt::from_frame(&frame),
            Err(WaveFrameError::UnsupportedVersion)
        );
    }

    #[test]
    fn zero_denominator_is_invalid_rational() {
        let mut frame = sample().to_frame();
        frame[6..10].copy_from_slice(&0u32.to_le_bytes()); // baseAmplitude den = 0
        frame[78] = checksum(&frame[..78]);
        assert_eq!(
            WaveInt::from_frame(&frame),
            Err(WaveFrameError::InvalidRational)
        );
    }

    #[test]
    fn coordinate_is_the_swift_grid_placement() {
        // valence = -1/2 → y_norm = 0.25 → y = floor(63.75) = 63.
        // frequency = consciousness → x = 128. Age 0 at createdAt → z = 0.
        let wave = sample();
        let (x, y, z) = wave.coordinate(Some(wave.created_at));
        assert_eq!(z, 0);
        assert_eq!(y, 63);
        assert_eq!(x, 128);
    }

    #[test]
    fn provenance_values_are_the_wire_contract() {
        assert_ne!(WaveProvenance::Cognitive as u8, WaveProvenance::Nexus as u8);
        assert_eq!(
            WaveProvenance::from_raw(0x01),
            Some(WaveProvenance::Cognitive)
        );
        assert_eq!(WaveProvenance::from_raw(0x02), Some(WaveProvenance::Nexus));
        assert_eq!(WaveProvenance::from_raw(0x07), None);
    }
}
