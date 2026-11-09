//! `agy_omni` — Sovereign `babilon-ultra-k9` (`Omni-God-of-Sun-Wukong`) Edge Telemetry,
//! 5-Trit `Tryte5` Classifier, `SLEB128` LoRa Codec, `PackLinkRadar`, and 79-Byte `WaveInt` Bridge.
//!
//! Bridges the `babilon-ultra-k9` (`NODE_BLUE` & `NODE_BELLA`) embedded collar pipeline directly
//! into `qwave-core`'s 79-byte `MEM|8` `WaveInt` substrate and exact `Rational` (`p/q`) accounting
//! with zero floating-point operations.

use crate::Rational;
use crate::quanttern::Trit;
use crate::vault::sha256;
use crate::wave::{WaveInt, WaveProvenance};

/// Maximum LoRa payload MTU in bytes.
pub const LORA_MAX_MTU: usize = 32;

/// Canonical node identifier for `NODE_BLUE` (`0x01`).
pub const NODE_BLUE_ID: u8 = 1;

/// Canonical node identifier for `NODE_BELLA` (`0x02`).
pub const NODE_BELLA_ID: u8 = 2;

/// Uncompressed raw telemetry + seal reference size in bytes (`24B / 16B = 3/2` Rung 0 Bonobo resonance).
pub const RAW_TELEMETRY_REF_BYTES: i32 = 24;

/// Rung 0 Bonobo target resonance (`p/q = 3/2`, `+1` trit).
#[inline]
pub const fn bonobo_resonance_pq() -> Rational {
    match Rational::new(3, 2) {
        Some(r) => r,
        None => Rational::ONE,
    }
}

/// Checks whether a reduced `Rational` equals the Rung 0 Bonobo target (`3/2`).
#[inline]
pub const fn is_bonobo_resonant(r: Rational) -> bool {
    r.num == 3 && r.den == 2
}

/// 5-trit balanced ternary vector (`[Trit; 5]`) packed into a single byte (`0..243`, since `3^5 = 243 <= 255`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Tryte5(pub u8);

impl Tryte5 {
    #[inline]
    pub const fn pack(trits: [Trit; 5]) -> Self {
        let mut acc: u8 = 0;
        let mut mult: u8 = 1;
        let mut i = 0;
        while i < 5 {
            let digit = (trits[i] as i8 + 1) as u8; // 0, 1, 2
            acc += digit * mult;
            if i < 4 {
                mult *= 3;
            }
            i += 1;
        }
        Self(acc)
    }

    #[inline]
    pub const fn unpack(self) -> [Trit; 5] {
        let mut val = self.0;
        let mut out = [Trit::Zero; 5];
        let mut i = 0;
        while i < 5 {
            let rem = val % 3;
            val /= 3;
            out[i] = match rem {
                0 => Trit::Minus,
                1 => Trit::Zero,
                _ => Trit::Plus,
            };
            i += 1;
        }
        out
    }

    /// Formats the 5 trits as a compact 5-character string (`-`, `0`, `+`).
    pub fn to_trit_string(self) -> String {
        let trits = self.unpack();
        let mut s = String::with_capacity(5);
        for t in trits {
            s.push(match t {
                Trit::Minus => '-',
                Trit::Zero => '0',
                Trit::Plus => '+',
            });
        }
        s
    }
}

/// Omni-God-of-Sun-Wukong 72-Transformations K9 Guardian posture.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum WukongPosture {
    /// Cloud-Somersault (`Jindouyun`) Deep Zen Recovery (`-1`)
    JindouyunRest = 0,
    /// Golden-Fillet (`Jinguzhou`) Sovereign Perimeter Patrol (`0`)
    JinguzhouPatrol = 1,
    /// Ruyi Jingu Bang (`13,500-Jin` Iron Rod) High-Drive Guardian Intercept (`+1`)
    RuyiIntercept = 2,
    /// Great Sage Equal to Heaven (`Qitian Dasheng`) Thermal/Cardio Sovereign Alert (`+1!`)
    QitianAlert = 3,
}

impl WukongPosture {
    #[inline]
    pub const fn from_trits(trits: [Trit; 5], tick: u64) -> (Self, u8) {
        let transform_index = ((tick % 72) as u8) + 1;
        let posture = match (trits[0], trits[2], trits[4]) {
            (_, Trit::Plus | Trit::Minus, _) => Self::QitianAlert,
            (Trit::Plus, _, Trit::Plus) => Self::RuyiIntercept,
            (Trit::Minus, _, _) => Self::JindouyunRest,
            _ => Self::JinguzhouPatrol,
        };
        (posture, transform_index)
    }

    #[inline]
    pub const fn label(self) -> &'static str {
        match self {
            Self::JindouyunRest => "JINDOUYUN-REST",
            Self::JinguzhouPatrol => "JINGUZHOU-PATROL",
            Self::RuyiIntercept => "RUYI-INTERCEPT",
            Self::QitianAlert => "QITIAN-ALERT",
        }
    }
}

/// Classifies canine biometric and kinematic telemetry into a 5-trit topological vector:
/// - Trit 0: Kinetic Regime (`-1` rest/sleep, `0` patrol/trot, `+1` high-drive sprint)
/// - Trit 1: Cadence Stability (`-1` irregular/limp, `0` steady gait, `+1` high-frequency burst)
/// - Trit 2: Thermal State (`-1` hypothermia `<37.2°C`, `0` nominal `37.2..39.3°C`, `+1` hyperthermia `>39.3°C`)
/// - Trit 3: Cardiopulmonary Load (`-1` deep rest, `0` nominal, `+1` peak exertion)
/// - Trit 4: Priority Alert Routing (`-1` low-power sleep, `0` standard LoRa cadence, `+1` immediate priority burst)
#[inline]
pub const fn classify_k9_telemetry(
    accel_mag_q16: u32,
    cadence_hz_q8: u16,
    temp_c_q8: i16,
    hr_bpm_q8: u16,
) -> [Trit; 5] {
    let kinetic = if accel_mag_q16 < 72_000 {
        Trit::Minus
    } else if accel_mag_q16 < 160_000 {
        Trit::Zero
    } else {
        Trit::Plus
    };

    let cadence = if cadence_hz_q8 < 128 {
        Trit::Minus
    } else if cadence_hz_q8 < 768 {
        Trit::Zero
    } else {
        Trit::Plus
    };

    let thermal = if temp_c_q8 < 9_523 {
        Trit::Minus
    } else if temp_c_q8 <= 10_060 {
        Trit::Zero
    } else {
        Trit::Plus
    };

    let cardio = if hr_bpm_q8 < (65 << 8) {
        Trit::Minus
    } else if hr_bpm_q8 <= (135 << 8) {
        Trit::Zero
    } else {
        Trit::Plus
    };

    let priority = if matches!(thermal, Trit::Plus | Trit::Minus)
        || (matches!(kinetic, Trit::Plus) && matches!(cardio, Trit::Plus))
    {
        Trit::Plus
    } else if matches!(kinetic, Trit::Minus) && matches!(cardio, Trit::Minus) {
        Trit::Minus
    } else {
        Trit::Zero
    };

    [kinetic, cadence, thermal, cardio, priority]
}

/// ZigZag + unsigned LEB128 varint encoder for compact delta coordinates.
#[inline]
pub fn encode_sleb128_zigzag(val: i64, buf: &mut [u8]) -> usize {
    let mut zz = ((val << 1) ^ (val >> 63)) as u64;
    let mut idx = 0;
    loop {
        if idx >= buf.len() {
            break;
        }
        let mut byte = (zz & 0x7F) as u8;
        zz >>= 7;
        if zz != 0 {
            byte |= 0x80;
        }
        buf[idx] = byte;
        idx += 1;
        if zz == 0 {
            break;
        }
    }
    idx
}

/// Decodes a ZigZag-encoded unsigned LEB128 varint back into a signed `i64`.
#[inline]
pub fn decode_sleb128_zigzag(buf: &[u8]) -> Option<(i64, usize)> {
    let mut result: u64 = 0;
    let mut shift = 0;
    for (idx, &byte) in buf.iter().enumerate() {
        result |= ((byte & 0x7F) as u64) << shift;
        if (byte & 0x80) == 0 {
            let signed = ((result >> 1) as i64) ^ -((result & 1) as i64);
            return Some((signed, idx + 1));
        }
        shift += 7;
        if shift >= 64 {
            return None;
        }
    }
    None
}

/// Exact integer square root (`floor(sqrt(n))`).
#[inline]
pub const fn isqrt_u64(n: u64) -> u64 {
    if n < 2 {
        return n;
    }
    let mut x = n;
    let mut y = (x + 1) >> 1;
    while y < x {
        x = y;
        y = (x + n / x) >> 1;
    }
    x
}

/// Converts microdegree `(d_lat_udeg, d_lon_udeg)` delta into `(north_dm, east_dm, euclidean_dm)`
/// in decimeters (`0.1 m`) at mid-latitude (`~47.5°N`, `cos(47.5°) ≈ 675/1000`).
#[inline]
pub const fn microdeg_delta_to_dm(d_lat_udeg: i32, d_lon_udeg: i32) -> (i64, i64, u64) {
    let north_dm = ((d_lat_udeg as i64) * 1113) / 1000;
    let east_dm = ((d_lon_udeg as i64) * 752) / 1000;
    let dist_sq = (north_dm.unsigned_abs().saturating_mul(north_dm.unsigned_abs()))
        .saturating_add(east_dm.unsigned_abs().saturating_mul(east_dm.unsigned_abs()));
    let dist_dm = isqrt_u64(dist_sq);
    (north_dm, east_dm, dist_dm)
}

/// Circular geofence sanctuary ("Ruyi Jingu Bang Perimeter") anchored at home coordinates.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct GeofenceZone {
    pub anchor_lat_microdeg: i32,
    pub anchor_lon_microdeg: i32,
    pub safe_radius_dm: u64,
    pub warn_radius_dm: u64,
}

impl GeofenceZone {
    #[inline]
    pub const fn new(
        anchor_lat_microdeg: i32,
        anchor_lon_microdeg: i32,
        safe_radius_dm: u64,
        warn_radius_dm: u64,
    ) -> Self {
        Self {
            anchor_lat_microdeg,
            anchor_lon_microdeg,
            safe_radius_dm,
            warn_radius_dm,
        }
    }

    /// Default sanctuary zone (`47.569200°N, 18.404800°E`, `150.0 m` safe, `300.0 m` warning).
    #[inline]
    pub const fn default_sanctuary() -> Self {
        Self::new(47_569_200, 18_404_800, 1_500, 3_000)
    }

    #[inline]
    pub const fn evaluate(&self, lat_microdeg: i32, lon_microdeg: i32) -> (u64, Trit) {
        let d_lat = lat_microdeg.wrapping_sub(self.anchor_lat_microdeg);
        let d_lon = lon_microdeg.wrapping_sub(self.anchor_lon_microdeg);
        let (_, _, dist_dm) = microdeg_delta_to_dm(d_lat, d_lon);
        let status = if dist_dm <= self.safe_radius_dm {
            Trit::Plus
        } else if dist_dm <= self.warn_radius_dm {
            Trit::Zero
        } else {
            Trit::Minus
        };
        (dist_dm, status)
    }
}

/// Dual-collar (`NODE_BLUE` & `NODE_BELLA`) pack separation and geofence reading.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PackRadarReading {
    pub separation_dm: u64,
    pub pack_cohesion_trit: Trit,
    pub blue_anchor_dm: u64,
    pub blue_geofence_trit: Trit,
    pub bella_anchor_dm: u64,
    pub bella_geofence_trit: Trit,
}

pub struct PackLinkRadar;

impl PackLinkRadar {
    #[inline]
    pub const fn evaluate(
        blue_lat_udeg: i32,
        blue_lon_udeg: i32,
        bella_lat_udeg: i32,
        bella_lon_udeg: i32,
        geofence: &GeofenceZone,
    ) -> PackRadarReading {
        let d_lat = blue_lat_udeg.wrapping_sub(bella_lat_udeg);
        let d_lon = blue_lon_udeg.wrapping_sub(bella_lon_udeg);
        let (_, _, separation_dm) = microdeg_delta_to_dm(d_lat, d_lon);

        let pack_cohesion_trit = if separation_dm <= 250 {
            Trit::Plus
        } else if separation_dm <= 800 {
            Trit::Zero
        } else {
            Trit::Minus
        };

        let (blue_anchor_dm, blue_geofence_trit) =
            geofence.evaluate(blue_lat_udeg, blue_lon_udeg);
        let (bella_anchor_dm, bella_geofence_trit) =
            geofence.evaluate(bella_lat_udeg, bella_lon_udeg);

        PackRadarReading {
            separation_dm,
            pack_cohesion_trit,
            blue_anchor_dm,
            blue_geofence_trit,
            bella_anchor_dm,
            bella_geofence_trit,
        }
    }
}

/// Sensor sample input for `AgyOmniCollarNode`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct K9SensorSample {
    pub accel_mag_q16: u32,
    pub cadence_hz_q8: u16,
    pub hr_bpm_q8: u16,
    pub temp_c_q8: i16,
    pub lat_microdeg: i32,
    pub lon_microdeg: i32,
    pub battery_mv: u16,
}

/// Encoded `<= 32-byte` LoRa burst with `Rational` (`p/q`) compression and `WaveInt` bridge.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AgyOmniBurst {
    pub node_id: u8,
    pub tick: u64,
    pub payload: [u8; LORA_MAX_MTU],
    pub len: usize,
    pub state_trits: [Trit; 5],
    pub state_tryte: Tryte5,
    pub wukong_posture: WukongPosture,
    pub wukong_transform_idx: u8,
    pub compression_pq: Rational,
    pub chain_digest: [u8; 32],
}

impl AgyOmniBurst {
    /// Returns the 64-bit truncated SHA-256 provenance MAC tag (`chain_digest[0..8]`).
    #[inline]
    pub fn mac_tag64(&self) -> u64 {
        u64::from_le_bytes(self.chain_digest[0..8].try_into().unwrap_or([0u8; 8]))
    }

    /// Projects this K9 telemetry burst directly into a 79-byte `MEM|8` `WaveInt` frame!
    /// - `base_amplitude`: normalized kinetic load (`1/4` rest, `1/2` patrol, `9/10` sprint)
    /// - `frequency`: consciousness gate (`73/100 Hz`) modulated by cadence regime
    /// - `emotional_valence` & `arousal`: mapped from the 5-trit `Tryte5` state vector
    pub fn to_wave_int(&self, cadence_hz_q8: u16, now_nanos: u64) -> WaveInt {
        let base_amplitude = match self.state_trits[0] {
            Trit::Minus => Rational::new(1, 4).unwrap_or(Rational::ONE),
            Trit::Zero => Rational::new(1, 2).unwrap_or(Rational::ONE),
            Trit::Plus => Rational::new(9, 10).unwrap_or(Rational::ONE),
        };
        let frequency = if cadence_hz_q8 == 0 {
            Rational::new(73, 100).unwrap_or(Rational::ONE)
        } else {
            // Scale around 73/100 Hz using cadence_hz_q8
            let num = (73i32 * i32::from(cadence_hz_q8.max(64))) / 256;
            Rational::new(num.max(1), 100).unwrap_or(Rational::ONE)
        };
        let phase = Rational::new(i32::from(self.wukong_transform_idx), 72).unwrap_or(Rational::ZERO);
        let emotional_valence = match self.state_trits[2] {
            Trit::Zero => Rational::new(1, 2).unwrap_or(Rational::ZERO),
            Trit::Plus => Rational::new(-1, 2).unwrap_or(Rational::ZERO),
            Trit::Minus => Rational::new(-3, 4).unwrap_or(Rational::ZERO),
        };
        let arousal = Rational::integer(self.state_trits[3].raw() as i32);
        let decay_rate = match self.state_trits[4] {
            Trit::Plus => Rational::new(1, 100).unwrap_or(Rational::ONE),
            Trit::Zero => Rational::new(1, 10).unwrap_or(Rational::ONE),
            Trit::Minus => Rational::new(1, 4).unwrap_or(Rational::ONE),
        };

        WaveInt {
            base_amplitude,
            frequency,
            phase,
            emotional_valence,
            arousal,
            created_at: now_nanos,
            last_accessed: now_nanos,
            access_count: (self.tick as u32).max(1),
            decay_rate,
            id: Some((u64::from(self.node_id) << 48) | self.tick),
            provenance: WaveProvenance::Cognitive,
        }
    }
}

/// Deterministic collar node state (`NODE_BLUE = 1`, `NODE_BELLA = 2`) bridged into `qwave-core`.
#[derive(Clone, Debug)]
pub struct AgyOmniCollarNode {
    pub node_id: u8,
    pub tick: u64,
    pub generation: u32,
    pub last_lat_microdeg: i32,
    pub last_lon_microdeg: i32,
    pub chain_state: [u8; 32],
}

impl AgyOmniCollarNode {
    pub const fn new(
        node_id: u8,
        initial_lat: i32,
        initial_lon: i32,
        genesis_seed: [u8; 32],
    ) -> Self {
        Self {
            node_id,
            tick: 0,
            generation: 1,
            last_lat_microdeg: initial_lat,
            last_lon_microdeg: initial_lon,
            chain_state: genesis_seed,
        }
    }

    /// Executes one deterministic collar tick, rolling the SHA-256 chain state and emitting a `<=32B` LoRa burst.
    pub fn step_cycle(&mut self, sample: K9SensorSample) -> AgyOmniBurst {
        self.tick = self.tick.wrapping_add(1);
        let prev_lat = self.last_lat_microdeg;
        let prev_lon = self.last_lon_microdeg;
        self.last_lat_microdeg = sample.lat_microdeg;
        self.last_lon_microdeg = sample.lon_microdeg;

        let mut frame_bytes = [0u8; 64];
        frame_bytes[0..32].copy_from_slice(&self.chain_state);
        frame_bytes[32..36].copy_from_slice(&sample.accel_mag_q16.to_le_bytes());
        frame_bytes[36..38].copy_from_slice(&sample.hr_bpm_q8.to_le_bytes());
        frame_bytes[38..40].copy_from_slice(&sample.temp_c_q8.to_le_bytes());
        frame_bytes[40..44].copy_from_slice(&sample.lat_microdeg.to_le_bytes());
        frame_bytes[44..48].copy_from_slice(&sample.lon_microdeg.to_le_bytes());
        frame_bytes[48..56].copy_from_slice(&self.tick.to_le_bytes());
        frame_bytes[56] = self.node_id;
        let digest = sha256(&frame_bytes);
        self.chain_state = digest;

        let state_trits = classify_k9_telemetry(
            sample.accel_mag_q16,
            sample.cadence_hz_q8,
            sample.temp_c_q8,
            sample.hr_bpm_q8,
        );
        let state_tryte = Tryte5::pack(state_trits);
        let (wukong_posture, wukong_transform_idx) =
            WukongPosture::from_trits(state_trits, self.tick);

        let mut payload = [0u8; LORA_MAX_MTU];
        let mut cursor = 0;
        payload[cursor] = self.node_id;
        cursor += 1;
        payload[cursor] = state_tryte.0;
        cursor += 1;

        cursor += encode_sleb128_zigzag(self.tick as i64, &mut payload[cursor..]);
        let d_lat = (sample.lat_microdeg - prev_lat) as i64;
        let d_lon = (sample.lon_microdeg - prev_lon) as i64;
        cursor += encode_sleb128_zigzag(d_lat, &mut payload[cursor..]);
        cursor += encode_sleb128_zigzag(d_lon, &mut payload[cursor..]);
        cursor += encode_sleb128_zigzag(sample.battery_mv as i64, &mut payload[cursor..]);

        let mac_len = 8.min(LORA_MAX_MTU.saturating_sub(cursor));
        payload[cursor..cursor + mac_len].copy_from_slice(&digest[..mac_len]);
        cursor += mac_len;

        let compression_pq =
            Rational::new(RAW_TELEMETRY_REF_BYTES, cursor as u32).unwrap_or(Rational::ONE);

        AgyOmniBurst {
            node_id: self.node_id,
            tick: self.tick,
            payload,
            len: cursor,
            state_trits,
            state_tryte,
            wukong_posture,
            wukong_transform_idx,
            compression_pq,
            chain_digest: digest,
        }
    }
}

/// Synthesizes deterministic trail kinematics for `NODE_BLUE` (`1`) and `NODE_BELLA` (`2`).
#[inline]
pub const fn synthesize_k9_sample(
    node_id: u8,
    tick: u64,
    base_lat: i32,
    base_lon: i32,
) -> K9SensorSample {
    let phase = (tick.wrapping_add((node_id as u64) * 3)) % 12;
    let (accel_mag_q16, cadence_hz_q8, hr_bpm, temp_q8) = match phase {
        0..=2 => (62_000, 64, 58, (38 << 8) + 20),
        3..=7 => (118_000, 512, 105, (38 << 8) + 140),
        8..=10 => (195_000, 890, 158, (39 << 8) + 40),
        _ => (210_000, 920, 168, (39 << 8) + 110),
    };

    let d_lat = ((tick as i32) * 14) * if node_id == 1 { 1 } else { -1 };
    let d_lon = ((tick as i32) * 19) + ((node_id as i32) * 45);
    let battery_mv = 4180u16.saturating_sub(((tick % 400) as u16) * 2);

    K9SensorSample {
        accel_mag_q16,
        cadence_hz_q8,
        hr_bpm_q8: hr_bpm << 8,
        temp_c_q8: temp_q8,
        lat_microdeg: base_lat + d_lat,
        lon_microdeg: base_lon + d_lon,
        battery_mv,
    }
}

/// C ABI: pack five trits (`-1, 0, +1`) into a single `Tryte5` byte (`0..243`).
#[unsafe(no_mangle)]
pub extern "C" fn qw_agy_omni_pack_tryte(t0: i8, t1: i8, t2: i8, t3: i8, t4: i8) -> u8 {
    let trits = [
        Trit::from_raw(t0).unwrap_or(Trit::Zero),
        Trit::from_raw(t1).unwrap_or(Trit::Zero),
        Trit::from_raw(t2).unwrap_or(Trit::Zero),
        Trit::from_raw(t3).unwrap_or(Trit::Zero),
        Trit::from_raw(t4).unwrap_or(Trit::Zero),
    ];
    Tryte5::pack(trits).0
}

/// C ABI: compute planar pack separation in decimeters (`0.1 m`) between two collars.
#[unsafe(no_mangle)]
pub extern "C" fn qw_agy_omni_pack_separation_dm(
    blue_lat_udeg: i32,
    blue_lon_udeg: i32,
    bella_lat_udeg: i32,
    bella_lon_udeg: i32,
) -> u64 {
    let d_lat = blue_lat_udeg.wrapping_sub(bella_lat_udeg);
    let d_lon = blue_lon_udeg.wrapping_sub(bella_lon_udeg);
    let (_, _, dist_dm) = microdeg_delta_to_dm(d_lat, d_lon);
    dist_dm
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tryte5_round_trips_all_243_states() {
        for raw in 0..243u8 {
            let t = Tryte5(raw);
            assert_eq!(Tryte5::pack(t.unpack()), t);
        }
    }

    #[test]
    fn collar_step_bridges_to_79_byte_waveint_and_bonobo_resonance() {
        let base_lat = 47_569_200;
        let base_lon = 18_404_800;
        let mut bella = AgyOmniCollarNode::new(2, base_lat, base_lon, [0xBE; 32]);
        let sample = synthesize_k9_sample(2, 1, base_lat, base_lon);
        let burst = bella.step_cycle(sample);

        assert_eq!(burst.len, 16);
        assert!(is_bonobo_resonant(burst.compression_pq));
        assert_eq!(burst.compression_pq, bonobo_resonance_pq());

        let wave = burst.to_wave_int(sample.cadence_hz_q8, 1_700_000_000_000_000_000);
        let frame = wave.to_frame();
        assert_eq!(frame.len(), 79);
        let decoded_wave = WaveInt::from_frame(&frame).unwrap();
        assert_eq!(decoded_wave, wave);
        let (x, y, z) = decoded_wave.coordinate(Some(1_700_000_005_000_000_000));
        assert!(x > 0 && y > 0 && z == 5);
    }

    #[test]
    fn pack_radar_and_c_abi_exports_work_without_floats() {
        let zone = GeofenceZone::new(47_569_200, 18_404_800, 1_500, 3_000);
        let reading = PackLinkRadar::evaluate(
            47_569_250,
            18_404_830,
            47_569_150,
            18_404_860,
            &zone,
        );
        assert_eq!(reading.pack_cohesion_trit, Trit::Plus);
        assert_eq!(reading.blue_geofence_trit, Trit::Plus);
        assert_eq!(reading.bella_geofence_trit, Trit::Plus);

        let sep = qw_agy_omni_pack_separation_dm(47_569_250, 18_404_830, 47_569_150, 18_404_860);
        assert_eq!(sep, reading.separation_dm);
        let packed = qw_agy_omni_pack_tryte(1, 1, 0, 1, 1);
        assert_eq!(packed, 233);
    }
}
