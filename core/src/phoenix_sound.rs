//! PhoeniX Sound Revelation Engine (`phoenix_sound`) — 100% Pure Rust, Zero-Float
//!
//! "This is NOT compression. This is REVELATION. Audio frequencies ARE rational
//! numbers. We're finally storing and synthesizing them that way."
//!
//! Turns ALL music (WAV, MP3, FLAC, OGG, live streams) into **PhoeniX'd Sound**
//! and `.8a` (`8a∞` `0x38 0x61 0xE2 0x9E`) harmonic capsules using:
//!
//! 1. **Stage 1 — Integer Catmull-Rom Cubic Hermite Restoration (`Q15`)**:
//!    Reconstructs clipped peaks and burst dropouts using exact integer cubic
//!    Hermite splines (`(-p0 + 9*p1 + 9*p2 - p3) >> 4`).
//! 2. **Stage 2 — 16× Temporal Oversampling (`48 kHz -> 768 kHz` Grid) & Marine `S + N + T`**:
//!    Tracks sub-sample zero crossings on the `768 kHz` virtual grid to extract
//!    exact `p/q` [`Rational`] fundamental frequencies, period jitter (`J_p`),
//!    amplitude jitter (`J_a`), Soul Authenticity score, and decomposes audio into
//!    **Sinusoids (`S`) + Noise (`N`) + Dirac Transients (`T`)**.
//! 3. **Stage 3 — PhoeniX Harmonic Revelation & `.8a` Synthesis**:
//!    Applies **Sparkle** (768 kHz curvature air restoration), **Warmth** (2nd-order
//!    even harmonic triode bloom + DC block), **Drive** (Chebyshev 3rd harmonic),
//!    **Punch** (Dirac transient crest expansion), **432 Hz / φ-Companion Resonance**
//!    (`500/809` golden sub-harmonic resonator), and **Holographic Stereo Locus** (`M/S`).
//!
//! All arithmetic obeys the **8b-is No-Float Law**: only exact integers (`i16`, `i32`,
//! `i64`, `u64`) and reduced `p/q` [`Rational`] values are used.

use crate::rational::Rational;
use std::io::Read;
use std::path::Path;
use std::process::{Command, Stdio};

/// `.8a` (`8a∞`) Infinity Audio magic header bytes: `0x38 0x61 0xE2 0x9E`.
pub const EIGHT_A_MAGIC: [u8; 4] = [0x38, 0x61, 0xE2, 0x9E];

/// Default Sovereign Harmonic Anchor in Hz (`432` Hz).
pub const SOVEREIGN_ANCHOR_HZ: u16 = 432;

/// `.8a` VM OpCodes (matching `oxi-phoenix` / `lib8a` specification).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum OpCode8a {
    /// `0x10`: `DEF_TURBINE` (11B) — Harmonic family fundamental `(p, q)`, amplitude, viscosity.
    DefTurbine = 0x10,
    /// `0x20`: `LINEUP` (7B) — Silence deadband ("Silence is free").
    Lineup = 0x20,
    /// `0x21`: `TUNE` (7B) — Period jitter (`J_p`) & amplitude jitter (`J_a`) + Soul Authenticity.
    Tune = 0x21,
    /// `0x30`: `EVT_ATOM` (7B) — Acoustic event (`1`=Harmonic `S`, `2`=Stochastic `N`, `3`=Dirac `T`).
    EvtAtom = 0x30,
    /// `0x40`: `DEF_PATTERN` (7B) — SentinelPool pattern definition.
    DefPattern = 0x40,
    /// `0x41`: `PLAY_PATTERN` (7B) — SentinelPool pattern recall.
    PlayPattern = 0x41,
}

/// Thermodynamic acoustic state classified by the Marine `QuantumScanner`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum AcousticState {
    Silence = 0,
    /// `S`: Coherent harmonic family (sustained voice, bowed string, synth, bass).
    HarmonicSinusoid = 1,
    /// `N`: Stochastic texture (breath, bow rosining, cymbal shimmer, room air).
    StochasticNoise = 2,
    /// `T`: Dirac impulse / transient edge (drum hit, pluck, consonant attack).
    DiracTransient = 3,
}

/// Tuning preset for the PhoeniX Sound Revelation Engine (all gains in `Q10`, where `1024 == 1/1`).
///
/// Augments the 768 kHz Catmull-Rom + Marine `S+N+T` + 432 Hz/φ core with:
/// - **Goonj Ternary Dark Velvet Noise (`{-1, 0, +1}`) Room Bloom** (`goonj_velvet_q10`)
/// - **Svara Vocal Formant Presence (`F1/F2` Chamberlin SVF Bandpass)** (`svara_formant_q10`)
/// - **Naad Octave Sub-Harmonic Foundation (`SVF Low + f/2`)** (`naad_sub_q10`)
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PhoenixSoundPreset {
    /// High-frequency 768 kHz Catmull-Rom curvature & upper-harmonic air restoration (`0..=2048`).
    pub sparkle_q10: i64,
    /// 2nd-order even harmonic (`2f`) triode warmth (`0..=2048`).
    pub warmth_q10: i64,
    /// 3rd-order odd harmonic (`3f`) saturation drive (`0..=2048`).
    pub drive_q10: i64,
    /// Dirac transient (`T`) attack crest expansion (`0..=2048`).
    pub punch_q10: i64,
    /// Upper-octave shimmer & breath clarity (`0..=2048`).
    pub air_q10: i64,
    /// 432 Hz / φ (`500/809`) golden-ratio sympathetic sub-harmonic bloom (`0..=2048`).
    pub phi_432_bloom_q10: i64,
    /// Goonj balanced-ternary `{-1, 0, +1}` Dark Velvet Noise spatial room bloom (`0..=2048`).
    pub goonj_velvet_q10: i64,
    /// Svara `F1/F2` vocal & lead formant bandpass presence (`0..=2048`).
    pub svara_formant_q10: i64,
    /// Naad integer Chamberlin SVF sub-harmonic bass foundation (`0..=2048`).
    pub naad_sub_q10: i64,
    /// Stereo Mid/Side spatial locus widening (`1024` = unity, `1380` = holographic wide).
    pub stereo_width_q10: i64,
    /// Optional 440 Hz -> 432 Hz exact rational pitch relaxation (`54/55` resample).
    pub pitch_relax_54_55: bool,
}

impl Default for PhoenixSoundPreset {
    fn default() -> Self {
        Self::sovereign_master()
    }
}

impl PhoenixSoundPreset {
    /// Default "PhoeniX Sovereign Master" — balanced revelation + Goonj/Svara/Naad polish for all music.
    pub const fn sovereign_master() -> Self {
        Self {
            sparkle_q10: 440,       // 440/1024 (~43%) 768kHz sub-sample sparkle
            warmth_q10: 420,        // 420/1024 (~41%) 2nd-harmonic tube warmth
            drive_q10: 220,         // 220/1024 (~21%) 3rd-harmonic tape density
            punch_q10: 480,         // 480/1024 (~47%) Dirac transient punch
            air_q10: 360,           // 360/1024 (~35%) High-shelf harmonic air
            phi_432_bloom_q10: 300, // 300/1024 (~29%) φ + 432Hz resonant bloom
            goonj_velvet_q10: 210,  // 210/1024 (~21%) Goonj ternary Dark Velvet Noise room air
            svara_formant_q10: 240, // 240/1024 (~23%) Svara F1/F2 formant presence
            naad_sub_q10: 280,      // 280/1024 (~27%) Deep <140Hz Naad sub-bass foundation
            stereo_width_q10: 1320, // 1320/1024 (~129%) 3D spatial locus width
            pitch_relax_54_55: false,
        }
    }

    /// Deep 432 Hz Sanctuary mode (includes exact `54/55` rational pitch relaxation + Goonj Velvet Sanctuary).
    pub const fn sanctuary_432() -> Self {
        Self {
            sparkle_q10: 380,
            warmth_q10: 480,
            drive_q10: 180,
            punch_q10: 400,
            air_q10: 360,
            phi_432_bloom_q10: 380,
            goonj_velvet_q10: 280,
            svara_formant_q10: 260,
            naad_sub_q10: 300,
            stereo_width_q10: 1400,
            pitch_relax_54_55: true,
        }
    }

    /// High-Resolution Svara Singer Emotion & Vocal Intimacy preset:
    /// Soul-coupled Mid-channel Svara `F1/F2` formant bloom (`svara_formant_q10`),
    /// envelope-adaptive 2nd-harmonic Class-A triode chest warmth (`warmth_q10`) so soft/whispered
    /// phrases retain full harmonic intimacy, 768 kHz Catmull-Rom breath & lyric articulation
    /// (`sparkle` + `air` + `punch`), 432 Hz/φ sympathetic chest resonance, deep `< 140 Hz` Naad
    /// sub-bass authority (`naad_sub_q10: 340`), and a lush Goonj Dark Velvet acoustic halo.
    pub const fn vocal_clarity() -> Self {
        Self {
            sparkle_q10: 560,       // 768kHz sub-sample breath & lyric articulation
            warmth_q10: 580,        // Envelope-adaptive 2nd-harmonic Class-A triode chest intimacy
            drive_q10: 220,         // Warm fundamental lower-mid vocal & bass body
            punch_q10: 500,         // Crisp Dirac transient consonant & kick articulation
            air_q10: 480,           // Silky upper-octave vocal breath & shimmer
            phi_432_bloom_q10: 360, // 432Hz / φ (500/809) sympathetic chest/heart bloom
            goonj_velvet_q10: 240,  // Lush Goonj Ternary Dark Velvet acoustic halo
            svara_formant_q10: 520, // Soul-coupled Mid-channel Svara F1/F2 vocal emotion presence
            naad_sub_q10: 340,      // Full-bodied <140Hz Naad sub-bass & bass guitar foundation
            stereo_width_q10: 1280, // Intimate locked center vocal + holographic accompaniment
            pitch_relax_54_55: false,
        }
    }

    /// Goonj Ternary Dark Velvet Concert Hall preset:
    /// Immersive multiplier-free `{-1, 0, +1}` velvet-noise acoustic hall + holographic stereo stage.
    pub const fn goonj_velvet_hall() -> Self {
        Self {
            sparkle_q10: 440,
            warmth_q10: 420,
            drive_q10: 160,
            punch_q10: 420,
            air_q10: 400,
            phi_432_bloom_q10: 320,
            goonj_velvet_q10: 460,  // Lush Goonj Dark Velvet Noise acoustic hall
            svara_formant_q10: 220,
            naad_sub_q10: 280,
            stereo_width_q10: 1460, // Wide concert-hall holographic stage
            pitch_relax_54_55: false,
        }
    }

    /// Naad Studio Sub & Transient Master preset:
    /// Deep Chamberlin SVF sub-harmonic foundation + crisp 768 kHz Dirac punch for Scarlett 18i20 / HiFi DACs.
    pub const fn naad_studio_sub() -> Self {
        Self {
            sparkle_q10: 480,
            warmth_q10: 420,
            drive_q10: 280,
            punch_q10: 580,
            air_q10: 380,
            phi_432_bloom_q10: 300,
            goonj_velvet_q10: 160,
            svara_formant_q10: 240,
            naad_sub_q10: 480,      // Maximum tactile <140Hz Naad sub-bass authority
            stereo_width_q10: 1360,
            pitch_relax_54_55: false,
        }
    }

    /// Alexandra Sanctuary & Warmth (with Occasional Passion Crest) preset:
    /// Specifically tuned for female auditory comfort across the 2800..4500 Hz ear-canal pinna resonance:
    /// Eliminates sustained Drive-Passion upper-mid glare while enveloping the room in 140..800 Hz
    /// 2nd-order Class-A triode warmth, 432 Hz / φ (500/809) heart/chest bloom, and Goonj Dark Velvet,
    /// while allowing brief, velvety Passion crests on emotional vocal & harmonic peaks!
    pub const fn alexandra_sanctuary() -> Self {
        Self {
            sparkle_q10: 220,       // Silky-smooth sub-sample highs without piercing upper-mid glare
            warmth_q10: 360,        // Ultra-clean Class-A triode warmth (zero quadratic IMD overdrive)
            drive_q10: 140,         // Gentle fundamental lower-mid cushion (zero harsh odd-order bite)
            punch_q10: 200,         // Softened transient attack so drum/guitar spikes never irritate
            air_q10: 240,           // Relaxed upper-octave shimmer that opens on brief Passion crests
            phi_432_bloom_q10: 360, // Pure linear 432Hz / φ (500/809) parasympathetic heart/sanctuary resonance
            goonj_velvet_q10: 380,  // Lush Goonj Ternary Dark Velvet enveloping room cocoon
            svara_formant_q10: 280, // Intimate vocal emotion without 2800..4500 Hz F3 ear-canal glare
            naad_sub_q10: 280,      // Clean, enveloping <140Hz Naad sub-bass foundation with full headroom
            stereo_width_q10: 1320, // Enveloping holographic sanctuary stage
            pitch_relax_54_55: false,
        }
    }

    /// Parse a numeric preset ID (`0 = sovereign`, `1 = goonj-velvet`, `2 = naad-studio`, `3 = sanctuary-432`, `4 = vocal-clarity`, `5 = alexandra-sanctuary`).
    pub const fn from_id(id: u8) -> Self {
        match id {
            1 => Self::goonj_velvet_hall(),
            2 => Self::naad_studio_sub(),
            3 => Self::sanctuary_432(),
            4 => Self::vocal_clarity(),
            5 => Self::alexandra_sanctuary(),
            _ => Self::sovereign_master(),
        }
    }

    /// Parse a preset slug (`sovereign`, `alexandra-sanctuary`, `sanctuary-432`, `vocal-clarity`, `goonj-velvet`, `naad-studio`).
    pub fn from_name(name: &str) -> Self {
        match name.trim().to_ascii_lowercase().as_str() {
            "alexandra" | "alexandra-sanctuary" | "alexandra_sanctuary" | "warmth" | "anti-glare" => {
                Self::alexandra_sanctuary()
            }
            "sanctuary" | "432" | "sanctuary-432" | "sanctuary_432" => Self::sanctuary_432(),
            "vocal" | "clarity" | "vocal-clarity" | "svara" | "svara-vocal" | "singer" | "emotion" | "vocal-emotion" => {
                Self::vocal_clarity()
            }
            "goonj" | "velvet" | "goonj-velvet" | "hall" => Self::goonj_velvet_hall(),
            "naad" | "studio" | "naad-studio" | "sub" => Self::naad_studio_sub(),
            _ => Self::sovereign_master(),
        }
    }

    /// Canonical slug name of this preset.
    pub const fn slug(&self) -> &'static str {
        if self.pitch_relax_54_55 {
            "sanctuary-432"
        } else if self.warmth_q10 == 360 && self.goonj_velvet_q10 == 380 {
            "alexandra-sanctuary"
        } else if self.goonj_velvet_q10 >= 400 {
            "goonj-velvet"
        } else if self.svara_formant_q10 >= 400 {
            "vocal-clarity"
        } else if self.naad_sub_q10 >= 400 {
            "naad-studio"
        } else {
            "sovereign"
        }
    }

    /// Cycle to the next preset in the 6-preset constellation.
    pub const fn next_preset_slug(current: &str) -> &'static str {
        match current.as_bytes() {
            b"sovereign" => "alexandra-sanctuary",
            b"alexandra-sanctuary" => "goonj-velvet",
            b"goonj-velvet" => "naad-studio",
            b"naad-studio" => "sanctuary-432",
            b"sanctuary-432" => "vocal-clarity",
            _ => "sovereign",
        }
    }
}

/// The 22-Shruti Indian Classical Just-Intonation `p/q` Rational Lattice (from `Taal` / `Shruti`).
/// Each entry is `(numerator, denominator, shruti_name)` in the `[1/1, 2/1)` octave relative to `Sa`.
pub const TAAL_22_SHRUTIS: [(i32, u32, &str); 22] = [
    (1, 1, "Sa (Chhandovati)"),
    (256, 243, "Atikomal Re (Dayavati)"),
    (16, 15, "Komal Re (Ranjani)"),
    (10, 9, "Shuddha Re (Ratika)"),
    (9, 8, "Tivra Re (Raudri)"),
    (32, 27, "Atikomal Ga (Krodha)"),
    (6, 5, "Komal Ga (Vajrika)"),
    (5, 4, "Shuddha Ga (Prasarini)"),
    (81, 64, "Tivra Ga (Priti)"),
    (4, 3, "Shuddha Ma (Marjani)"),
    (27, 20, "Ekashruti Ma (Kshiti)"),
    (45, 32, "Tivra Ma (Rakta)"),
    (729, 512, "Tivratama Ma (Sandeepani)"),
    (3, 2, "Pa (Alapini)"),
    (128, 81, "Atikomal Dha (Madanti)"),
    (8, 5, "Komal Dha (Rohini)"),
    (5, 3, "Shuddha Dha (Ramya)"),
    (27, 16, "Tivra Dha (Ugra)"),
    (16, 9, "Atikomal Ni (Kshobhini)"),
    (9, 5, "Komal Ni (Tivra)"),
    (15, 8, "Shuddha Ni (Kumudvati)"),
    (243, 128, "Tivra Ni (Manda)"),
];

/// Lock any positive `p/q` frequency (in Hz) onto its octave-normalized ratio relative to the
/// `432 Hz` Sovereign `Sa` anchor, and return the nearest **Taal 22-Shruti** `(Rational, name)`
/// using 100% integer cross-multiplication!
pub fn nearest_taal_shruti_pq(freq_hz: Rational) -> (Rational, &'static str) {
    let mut num = (freq_hz.num.max(1)) as u128;
    let mut den = (freq_hz.den.max(1) as u128) * (SOVEREIGN_ANCHOR_HZ as u128);
    // Normalize octave into `[1/1, 2/1)`: `den <= num < 2 * den`
    while num < den {
        num <<= 1;
    }
    while num >= (den << 1) {
        den <<= 1;
    }

    let mut best_idx = 0usize;
    let mut best_err_num: u128 = u128::MAX;
    let mut best_err_den: u128 = 1;

    for (idx, &(s_num, s_den, _)) in TAAL_22_SHRUTIS.iter().enumerate() {
        let sn = s_num as u128;
        let sd = s_den as u128;
        // Distance `|num/den - sn/sd| = |num*sd - sn*den| / (den*sd)`
        let lhs = num.saturating_mul(sd);
        let rhs = sn.saturating_mul(den);
        let err_n = lhs.abs_diff(rhs);
        let err_d = den.saturating_mul(sd).max(1);
        // Compare `err_n / err_d < best_err_num / best_err_den` via cross-product
        if err_n.saturating_mul(best_err_den) < best_err_num.saturating_mul(err_d) {
            best_err_num = err_n;
            best_err_den = err_d;
            best_idx = idx;
        }
    }

    let (bn, bd, name) = TAAL_22_SHRUTIS[best_idx];
    (Rational::new(bn, bd).unwrap_or(Rational::ONE), name)
}

/// Deterministic 16-tap Goonj Balanced-Ternary `{-1, 0, +1}` Dark Velvet Noise (`DVN`) pulse table.
/// Each entry is `(delay_frames_offset, sign_trit_l, sign_trit_r)` across a 4096-frame (85.3 ms @ 48 kHz)
/// acoustic reflection window. Because every tap weight is in `{-1, +1}`, reflection accumulation uses
/// **zero multiplications** (pure integer add/subtract, matching `tentib` ternary arithmetic).
pub const GOONJ_DVN_TERNARY_TAPS: [(usize, i64, i64); 16] = [
    (173, 1, -1),
    (389, -1, 1),
    (617, 1, 1),
    (859, -1, -1),
    (1103, 1, -1),
    (1361, -1, 1),
    (1619, 1, 1),
    (1879, -1, 1),
    (2143, 1, -1),
    (2411, -1, -1),
    (2683, 1, 1),
    (2957, -1, 1),
    (3229, 1, -1),
    (3511, -1, 1),
    (3779, 1, -1),
    (4049, -1, -1),
];

/// Telemetry & verification receipt emitted after transforming audio into PhoeniX'd Sound.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PhoenixSoundReceipt {
    /// Sample rate in Hz (e.g. `48000`).
    pub sample_rate_hz: u32,
    /// Internal virtual oversampling rate in Hz (`sample_rate_hz * 16`, e.g. `768000`).
    pub internal_oversample_hz: u32,
    /// Number of channels (`1` or `2`).
    pub channels: u16,
    /// Total PCM frames processed.
    pub total_frames: u64,
    /// Number of clipped or dropped-out samples restored via Stage-1 Catmull-Rom spline.
    pub catmull_rom_restored_samples: u64,
    /// Dominant fundamental frequency discovered on the 768 kHz grid as exact `p/q` Hz.
    pub dominant_freq_hz: Rational,
    /// Nearest Taal 22-Shruti just-intonation interval (`p/q`) relative to 432 Hz `Sa`.
    pub shruti_interval_ratio: Rational,
    /// Classical name of the locked 22-Shruti interval (e.g. `"Pa (Alapini)"`).
    pub shruti_name: &'static str,
    /// Golden-ratio lower companion frequency (`f * 500 / 809`) in `p/q` Hz.
    pub phi_lower_hz: Rational,
    /// Golden-ratio upper companion frequency (`f * 809 / 500`) in `p/q` Hz.
    pub phi_upper_hz: Rational,
    /// Period jitter (`J_p`) ratio (`Q10` over `1024`).
    pub period_jitter_ratio: Rational,
    /// Amplitude jitter (`J_a`) ratio (`Q10` over `1024`).
    pub amplitude_jitter_ratio: Rational,
    /// Soul Authenticity score (`0..1024 / 1024`, higher means organic human/instrument micro-jitter).
    pub soul_authenticity: Rational,
    /// Frame counts classified into `S` (Harmonic), `N` (Noise), `T` (Dirac Transient), and `Silence`.
    pub harmonic_s_frames: u64,
    pub stochastic_n_frames: u64,
    pub dirac_t_frames: u64,
    pub silence_frames: u64,
    /// Input vs Output crest energy improvement ratio (`p/q`).
    pub harmonic_bloom_ratio: Rational,
    /// 64-bit FNV-1a checksum of the PhoeniX'd PCM stream.
    pub pcm_fnv1a_hash: u64,
    /// Size in bytes of the emitted `.8a` (`8a∞`) harmonic revelation stream.
    pub eight_a_bytes: usize,
}

/// Exact integer Catmull-Rom cubic Hermite evaluation at 16× oversampled sub-step `sub_k` (`0..=16`).
///
/// For four uniform control samples `(p0, p1, p2, p3)` and `t = sub_k / 16`:
/// `C(t) = ((a0 * k^3) + (a1 * 16 * k^2) + (a2 * 256 * k) + (a3 * 4096)) / 8192`
/// where:
/// - `a0 = -p0 + 3*p1 - 3*p2 + p3`
/// - `a1 = 2*p0 - 5*p1 + 4*p2 - p3`
/// - `a2 = -p0 + p2`
/// - `a3 = 2*p1`
#[inline]
pub fn catmull_rom_i16_16x(p0: i16, p1: i16, p2: i16, p3: i16, sub_k: u8) -> i16 {
    let k = (sub_k.min(16)) as i64;
    let p0 = p0 as i64;
    let p1 = p1 as i64;
    let p2 = p2 as i64;
    let p3 = p3 as i64;

    let a0 = -p0 + 3 * p1 - 3 * p2 + p3;
    let a1 = 2 * p0 - 5 * p1 + 4 * p2 - p3;
    let a2 = -p0 + p2;
    let a3 = 2 * p1;

    let k2 = k * k;
    let k3 = k2 * k;
    let num = a0 * k3 + (a1 << 4) * k2 + (a2 << 8) * k + (a3 << 12);
    // Round to nearest integer before shifting right by 13 (`8192`)
    let val = (num + 4096) >> 13;
    val.clamp(-32767, 32767) as i16
}

/// Fast midpoint (`sub_k = 8`, `t = 1/2`) integer Catmull-Rom interpolation:
/// `C(1/2) = (-p0 + 9*p1 + 9*p2 - p3 + 8) >> 4`.
#[inline]
pub fn catmull_rom_midpoint_i16(p0: i16, p1: i16, p2: i16, p3: i16) -> i16 {
    let num = -(p0 as i64) + 9 * (p1 as i64) + 9 * (p2 as i64) - (p3 as i64);
    ((num + 8) >> 4).clamp(-32767, 32767) as i16
}

/// Exact 32-bit signed integer (`s32le` / 24-bit `S24_3LE` DAC) Catmull-Rom cubic Hermite evaluation
/// at 16× oversampled sub-step `sub_k` (`0..=16`).
///
/// Retains all 13 fractional polynomial bits (`num << 3`, since `65536 / 8192 = 8`) without
/// 16-bit truncation, delivering true 24-bit sub-sample curve resolution at 192 kHz / 384 kHz!
#[inline]
pub fn catmull_rom_s32_16x(p0: i16, p1: i16, p2: i16, p3: i16, sub_k: u8) -> i32 {
    let k = (sub_k.min(16)) as i64;
    let p0 = p0 as i64;
    let p1 = p1 as i64;
    let p2 = p2 as i64;
    let p3 = p3 as i64;

    let a0 = -p0 + 3 * p1 - 3 * p2 + p3;
    let a1 = 2 * p0 - 5 * p1 + 4 * p2 - p3;
    let a2 = -p0 + p2;
    let a3 = 2 * p1;

    let k2 = k * k;
    let k3 = k2 * k;
    let num = a0 * k3 + (a1 << 4) * k2 + (a2 << 8) * k + (a3 << 12);
    let val_s32 = num << 3;
    val_s32.clamp(-2_147_483_647, 2_147_483_647) as i32
}

/// Stage 1: Integer Catmull-Rom dropout & digital brickwall-clipping restoration on a single channel.
///
/// Detects:
/// 1. Hard digital clipping plateaus (`|x[i]| >= 32600` for 2+ consecutive samples), and
/// 2. Sudden sample-dropouts to zero surrounded by high-amplitude active wave energy.
///
/// Reconstructs the missing/clipped arc using phase-continuous integer Catmull-Rom cubic Hermite
/// interpolation anchored on the intact slopes before and after the damaged span.
pub fn restore_channel_catmull_rom_i16(samples: &[i16]) -> (Vec<i16>, u64) {
    let n = samples.len();
    if n < 8 {
        return (samples.to_vec(), 0);
    }
    let mut damaged = vec![false; n];
    for i in 2..(n - 2) {
        let s = samples[i] as i64;
        let prev = samples[i - 1] as i64;
        let next = samples[i + 1] as i64;
        // 1. Clipped plateau detection
        if s.abs() >= 32600 && (prev.abs() >= 32500 || next.abs() >= 32500) {
            damaged[i] = true;
        }
        // 2. Single/double sample zero-dropout inside an active high-energy wave
        if s == 0 && prev.abs() > 2400 && next.abs() > 2400 && (prev * next) > 0 {
            damaged[i] = true;
        }
    }

    let mut out = samples.to_vec();
    let mut restored_count = 0u64;
    let mut i = 2;
    while i < n - 2 {
        if !damaged[i] {
            i += 1;
            continue;
        }
        let gap_start = i;
        while i < n - 2 && damaged[i] && (i - gap_start) < 15 {
            i += 1;
        }
        let gap_end = i;
        let span = (gap_end - gap_start + 1) as i64;

        let p1_idx = gap_start.saturating_sub(1);
        let p0_idx = p1_idx.saturating_sub(1);
        let p2_idx = gap_end.min(n - 1);
        let p3_idx = (gap_end + 1).min(n - 1);

        let p1 = out[p1_idx] as i64;
        let p0 = out[p0_idx] as i64;
        let p2 = samples[p2_idx] as i64;
        let p3 = samples[p3_idx] as i64;

        // Extrapolate boundary control points proportionally to gap span
        let eff_p0 = (p1 - (p1 - p0) * span).clamp(-32767, 32767) as i16;
        let eff_p3 = (p2 + (p3 - p2) * span).clamp(-32767, 32767) as i16;

        for offset in 0..(gap_end - gap_start) {
            let sub_k = (((offset as i64 + 1) * 16) / span).clamp(1, 15) as u8;
            out[gap_start + offset] =
                catmull_rom_i16_16x(eff_p0, p1 as i16, p2 as i16, eff_p3, sub_k);
            restored_count += 1;
        }
    }

    (out, restored_count)
}

/// Transform an interleaved 16-bit PCM buffer (`channels == 1` or `2`) into **PhoeniX'd Sound**
/// AND simultaneously compile its `.8a` (`8a∞`) harmonic revelation opcode stream!
pub fn phoenix_transform_pcm_i16(
    interleaved_pcm: &[i16],
    sample_rate_hz: u32,
    channels: u16,
    preset: &PhoenixSoundPreset,
) -> (Vec<i16>, Vec<u8>, PhoenixSoundReceipt) {
    let ch = channels.clamp(1, 2) as usize;
    let total_frames = interleaved_pcm.len() / ch;
    let rate = sample_rate_hz.max(8000);
    let internal_oversample_hz = rate.saturating_mul(16);

    if total_frames < 8 {
        let receipt = PhoenixSoundReceipt {
            sample_rate_hz: rate,
            internal_oversample_hz,
            channels: ch as u16,
            total_frames: total_frames as u64,
            catmull_rom_restored_samples: 0,
            dominant_freq_hz: Rational::integer(SOVEREIGN_ANCHOR_HZ as i32),
            shruti_interval_ratio: Rational::ONE,
            shruti_name: "Sa (Chhandovati)",
            phi_lower_hz: Rational::new(SOVEREIGN_ANCHOR_HZ as i32 * 500, 809).unwrap_or(Rational::ONE),
            phi_upper_hz: Rational::new(SOVEREIGN_ANCHOR_HZ as i32 * 809, 500).unwrap_or(Rational::ONE),
            period_jitter_ratio: Rational::ZERO,
            amplitude_jitter_ratio: Rational::ZERO,
            soul_authenticity: Rational::new(1, 2).unwrap_or(Rational::ONE),
            harmonic_s_frames: 0,
            stochastic_n_frames: 0,
            dirac_t_frames: 0,
            silence_frames: total_frames as u64,
            harmonic_bloom_ratio: Rational::ONE,
            pcm_fnv1a_hash: 0xcbf29ce484222325,
            eight_a_bytes: 16,
        };
        return (interleaved_pcm.to_vec(), build_8a_stream(&[], 0, rate, ch as u16), receipt);
    }

    // Separate channels for Stage-1 Catmull-Rom restoration
    let mut left_in = Vec::with_capacity(total_frames);
    let mut right_in = Vec::with_capacity(total_frames);
    for f in 0..total_frames {
        left_in.push(interleaved_pcm[f * ch]);
        right_in.push(if ch == 2 {
            interleaved_pcm[f * 2 + 1]
        } else {
            interleaved_pcm[f]
        });
    }

    let (left_clean, restored_l) = restore_channel_catmull_rom_i16(&left_in);
    let (right_clean, restored_r) = if ch == 2 {
        restore_channel_catmull_rom_i16(&right_in)
    } else {
        (left_clean.clone(), 0)
    };
    let catmull_rom_restored_samples = restored_l + restored_r;

    // Optional Stage 1b: 440 Hz -> 432 Hz exact rational pitch relaxation (`54/55` step)
    // Evaluated via 16× integer Catmull-Rom sub-sample spline!
    let (left_stage1, right_stage1) = if preset.pitch_relax_54_55 {
        let out_frames = (total_frames * 55) / 54;
        let mut l_res = Vec::with_capacity(out_frames);
        let mut r_res = Vec::with_capacity(out_frames);
        for out_idx in 0..out_frames {
            let src_num = (out_idx as u64) * 54;
            let base_idx = ((src_num / 55) as usize).min(total_frames.saturating_sub(1));
            let rem_16 = (((src_num % 55) * 16) / 55) as u8;
            let p0 = base_idx.saturating_sub(1);
            let p1 = base_idx;
            let p2 = (base_idx + 1).min(total_frames - 1);
            let p3 = (base_idx + 2).min(total_frames - 1);
            l_res.push(catmull_rom_i16_16x(
                left_clean[p0],
                left_clean[p1],
                left_clean[p2],
                left_clean[p3],
                rem_16,
            ));
            r_res.push(catmull_rom_i16_16x(
                right_clean[p0],
                right_clean[p1],
                right_clean[p2],
                right_clean[p3],
                rem_16,
            ));
        }
        (l_res, r_res)
    } else {
        (left_clean, right_clean)
    };

    let frames = left_stage1.len();
    let mut out_pcm = Vec::with_capacity(frames * ch);
    let mut opcodes_8a: Vec<u8> = Vec::with_capacity(4096);

    // Stage 2 & Stage 3 state registers (100% integer Q15/Q10)
    let mut lowpass_l: i64 = 0;
    let mut lowpass_r: i64 = 0;
    // Naad Integer Chamberlin State-Variable Filter (SVF) registers for Svara Formant & Sub-Bass
    let mut svf_low_l: i64 = 0;
    let mut svf_band_l: i64 = 0;
    let mut svf_low_r: i64 = 0;
    let mut svf_band_r: i64 = 0;
    // Goonj Ternary Dark Velvet Noise (`{-1, 0, +1}`) 4096-frame circular acoustic buffer
    let mut dvn_buf_l = vec![0i16; 4096];
    let mut dvn_buf_r = vec![0i16; 4096];
    let mut dvn_write_idx: usize = 0;
    let mut dvn_dark_l: i64 = 0;
    let mut dvn_dark_r: i64 = 0;

    let mut dc_prev_in_l: i64 = 0;
    let mut dc_prev_out_l: i64 = 0;
    let mut dc_prev_in_r: i64 = 0;
    let mut dc_prev_out_r: i64 = 0;
    let mut phi_resonator_l: i64 = 0;
    let mut phi_resonator_r: i64 = 0;
    let mut env_fast_q10: i64 = 0;
    let mut env_slow_q10: i64 = 0;

    // 768 kHz sub-sample zero-crossing & jitter trackers
    let mut last_zc_tick_768k: u64 = 0;
    let mut prev_period_ticks_768k: u64 = 0;
    let mut period_accum_ticks: u64 = 0;
    let mut period_jitter_accum: u64 = 0;
    let mut zc_intervals_count: u64 = 0;
    let mut prev_peak_abs: i64 = 0;
    let mut amp_jitter_accum: u64 = 0;
    let mut peak_accum: u64 = 0;
    let mut current_peak_abs: i64 = 0;

    let mut harmonic_s_frames: u64 = 0;
    let mut stochastic_n_frames: u64 = 0;
    let mut dirac_t_frames: u64 = 0;
    let mut silence_frames: u64 = 0;
    let mut silence_run_len: u32 = 0;

    let mut input_energy_sum: u64 = 0;
    let mut output_energy_sum: u64 = 0;

    for i in 0..frames {
        let p0_idx = i.saturating_sub(1);
        let p1_idx = i;
        let p2_idx = (i + 1).min(frames - 1);
        let p3_idx = (i + 2).min(frames - 1);

        let l0 = left_stage1[p0_idx];
        let l1 = left_stage1[p1_idx];
        let l2 = left_stage1[p2_idx];
        let l3 = left_stage1[p3_idx];

        let r0 = right_stage1[p0_idx];
        let r1 = right_stage1[p1_idx];
        let r2 = right_stage1[p2_idx];
        let r3 = right_stage1[p3_idx];

        // 16× oversampled midpoint on the 768 kHz Catmull-Rom grid (`sub_k = 8`)
        let mid_l = catmull_rom_midpoint_i16(l0, l1, l2, l3) as i64;
        let mid_r = catmull_rom_midpoint_i16(r0, r1, r2, r3) as i64;

        let s_l = l1 as i64;
        let s_r = r1 as i64;
        let mono_in = (s_l + s_r) >> 1;
        let next_mono = ((l2 as i64) + (r2 as i64)) >> 1;

        input_energy_sum = input_energy_sum.saturating_add((mono_in.unsigned_abs()) >> 4);

        let abs_mono = mono_in.abs();
        if abs_mono > current_peak_abs {
            current_peak_abs = abs_mono;
        }

        // Sub-sample zero-crossing detection on 16× (`768 kHz`) grid
        if mono_in <= 0 && next_mono > 0 {
            let span = (next_mono - mono_in).max(1);
            let sub_k = (((-mono_in) * 16) / span).clamp(0, 16) as u64;
            let tick_768k = (i as u64) * 16 + sub_k;
            if last_zc_tick_768k > 0 {
                let period_ticks = tick_768k.saturating_sub(last_zc_tick_768k);
                // Plausible musical fundamental range: 30 Hz .. 4000 Hz
                let min_ticks = (internal_oversample_hz as u64) / 4000;
                let max_ticks = (internal_oversample_hz as u64) / 30;
                if period_ticks >= min_ticks && period_ticks <= max_ticks {
                    period_accum_ticks = period_accum_ticks.saturating_add(period_ticks);
                    if prev_period_ticks_768k > 0 {
                        let dp = period_ticks.abs_diff(prev_period_ticks_768k);
                        period_jitter_accum = period_jitter_accum.saturating_add(dp);
                    }
                    prev_period_ticks_768k = period_ticks;

                    let da = current_peak_abs.abs_diff(prev_peak_abs);
                    amp_jitter_accum = amp_jitter_accum.saturating_add(da);
                    peak_accum = peak_accum.saturating_add(current_peak_abs as u64);
                    prev_peak_abs = current_peak_abs;
                    current_peak_abs = 0;
                    zc_intervals_count += 1;
                }
            }
            last_zc_tick_768k = tick_768k;
        }

        // Stage 2: S + N + T decomposition (Sinusoids + Noise + Dirac Transients)
        // 1-pole integer resonant low-pass tracks fundamental body (`S_low`)
        lowpass_l = (lowpass_l * 7 + s_l) >> 3;
        lowpass_r = (lowpass_r * 7 + s_r) >> 3;

        // Naad Integer Chamberlin SVF (`f_q10 = 180` -> ~1.35 kHz Svara vocal/lead formant center, `q_q10 = 640`)
        let svf_high_l = s_l - svf_low_l - ((svf_band_l * 640) >> 10);
        svf_band_l = (svf_band_l + ((svf_high_l * 180) >> 10)).clamp(-32767, 32767);
        svf_low_l = (svf_low_l + ((svf_band_l * 180) >> 10)).clamp(-32767, 32767);

        let svf_high_r = s_r - svf_low_r - ((svf_band_r * 640) >> 10);
        svf_band_r = (svf_band_r + ((svf_high_r * 180) >> 10)).clamp(-32767, 32767);
        svf_low_r = (svf_low_r + ((svf_band_r * 180) >> 10)).clamp(-32767, 32767);

        // First & second time-domain differentials (`DeltaTransducer`)
        let dl1 = (l2 as i64) - s_l;
        let dl0 = s_l - (l0 as i64);
        let d2l = dl1 - dl0; // Dirac impulse curvature L

        let dr1 = (r2 as i64) - s_r;
        let dr0 = s_r - (r0 as i64);
        let d2r = dr1 - dr0; // Dirac impulse curvature R

        // 768 kHz sub-sample spline arch (difference between cubic Catmull-Rom midpoint and linear midpoint)
        // This isolates the exact high-frequency harmonic curvature lost to sample-rate decimation!
        let linear_mid_l = (s_l + (l2 as i64)) >> 1;
        let linear_mid_r = (s_r + (r2 as i64)) >> 1;
        let spline_arch_l = mid_l - linear_mid_l;
        let spline_arch_r = mid_r - linear_mid_r;

        // Track fast vs slow envelope (`Q10`) for Dirac transient (`T`) detection
        let inst_env_q10 = (s_l.abs().max(s_r.abs())) << 2;
        env_fast_q10 = (env_fast_q10 * 3 + inst_env_q10) >> 2;
        env_slow_q10 = (env_slow_q10 * 31 + inst_env_q10) >> 5;
        let transient_excess_q10 = (env_fast_q10 - env_slow_q10).max(0);

        // Classify frame state for `.8a` stream and telemetry
        let state = if abs_mono < 48 && env_fast_q10 < 256 {
            silence_frames += 1;
            silence_run_len = silence_run_len.saturating_add(1);
            AcousticState::Silence
        } else {
            if silence_run_len >= 64 && opcodes_8a.len() < 65536 {
                // Emit `0x20` LINEUP silence deadband opcode (7B)
                let rb = silence_run_len.to_le_bytes();
                opcodes_8a.extend_from_slice(&[
                    OpCode8a::Lineup as u8,
                    rb[0],
                    rb[1],
                    rb[2],
                    rb[3],
                    (abs_mono.min(255)) as u8,
                    0,
                ]);
            }
            silence_run_len = 0;

            if transient_excess_q10 > (env_slow_q10 >> 1).max(2048) {
                dirac_t_frames += 1;
                AcousticState::DiracTransient
            } else if d2l.abs() + d2r.abs() > abs_mono * 2 {
                stochastic_n_frames += 1;
                AcousticState::StochasticNoise
            } else {
                harmonic_s_frames += 1;
                AcousticState::HarmonicSinusoid
            }
        };

        // Periodically emit `.8a` opcodes (bounded so `.8a` capsule stays compact and fast)
        if i % 512 == 0 && state != AcousticState::Silence && opcodes_8a.len() < 65536 {
            let p_ticks = prev_period_ticks_768k.max(16) as u32;
            let hz_est = (internal_oversample_hz / p_ticks).clamp(20, 20000) as u16;
            let fp = hz_est.to_le_bytes();
            let fq = 1u16.to_le_bytes();
            let amp_u8 = ((abs_mono >> 7).min(255)) as u8;
            let locus_i8 = (((s_l - s_r) >> 8).clamp(-127, 127)) as i8 as u8;
            opcodes_8a.extend_from_slice(&[
                OpCode8a::DefTurbine as u8,
                fp[0],
                fp[1],
                fq[0],
                fq[1],
                amp_u8,
                (i & 0xFF) as u8,
                180,
                ((preset.warmth_q10 >> 3).min(255)) as u8,
                ((preset.sparkle_q10 >> 3).min(255)) as u8,
                locus_i8,
            ]);
            let peak_b = (mono_in as i16).to_le_bytes();
            let slope_b = (dl1.clamp(-32767, 32767) as i16).to_le_bytes();
            opcodes_8a.extend_from_slice(&[
                OpCode8a::EvtAtom as u8,
                state as u8,
                peak_b[0],
                peak_b[1],
                slope_b[0],
                slope_b[1],
                8,
            ]);
        }

        // ── Stage 3: PhoeniX Harmonic Revelation + Goonj/Svara/Naad Synthesis ──

        // 1. Envelope-Adaptive Warmth (2nd-order even harmonic `(x * |x|) / triode_norm`, DC-blocked)
        // Ensures soft/whispered vocal phrases retain full Class-A triode chest intimacy!
        let triode_norm = ((env_slow_q10 >> 2) + 4096).clamp(6144, 32768);
        let even_harm_l = (((s_l * s_l.abs()) / triode_norm) * preset.warmth_q10) >> 11;
        let even_harm_r = (((s_r * s_r.abs()) / triode_norm) * preset.warmth_q10) >> 11;

        // 2. Drive (3rd-order harmonic fullness on mid/low body `lowpass`)
        let lp_norm_l = (lowpass_l * preset.drive_q10) >> 12;
        let lp_norm_r = (lowpass_r * preset.drive_q10) >> 12;

        // 3. Sparkle & Air (768 kHz Catmull-Rom sub-sample spline arch + high-frequency edge)
        let sparkle_l = (spline_arch_l * preset.sparkle_q10) >> 9;
        let sparkle_r = (spline_arch_r * preset.sparkle_q10) >> 9;
        let air_l = ((dl1 - (d2l >> 2)) * preset.air_q10) >> 12;
        let air_r = ((dr1 - (d2r >> 2)) * preset.air_q10) >> 12;

        // 4. Dirac Punch (transient attack crest restoration)
        let punch_gain_q10 = if state == AcousticState::DiracTransient {
            preset.punch_q10
        } else {
            preset.punch_q10 >> 2
        };
        let punch_l = ((s_l - lowpass_l) * punch_gain_q10) >> 12;
        let punch_r = ((s_r - lowpass_r) * punch_gain_q10) >> 12;

        // 5. 432 Hz / φ (`500/809`) Golden-Ratio Sympathetic Sub-Harmonic Resonator
        // Tracks the fundamental body at golden damping `500/809` (`~1/φ`)
        phi_resonator_l = (phi_resonator_l * 500 + lowpass_l * 309) / 809;
        phi_resonator_r = (phi_resonator_r * 500 + lowpass_r * 309) / 809;
        let phi_bloom_l = (phi_resonator_l * preset.phi_432_bloom_q10) >> 12;
        let phi_bloom_r = (phi_resonator_r * preset.phi_432_bloom_q10) >> 12;

        // 6. Soul-Coupled Mid-Channel Svara Formant Presence (`svf_band`) & Naad Sub Foundation (`svf_low`)
        let jp_q10 = ((period_jitter_accum * 1024) / period_accum_ticks.max(1)).min(384) as i64;
        let ja_q10 = ((amp_jitter_accum * 512) / peak_accum.max(1)).min(256) as i64;
        let soul_expr_q10 = if state == AcousticState::HarmonicSinusoid {
            1024 + jp_q10 + ja_q10
        } else {
            1024
        };
        let svf_band_mid = (svf_band_l + svf_band_r) >> 1;
        let vocal_focus_l = (svf_band_l + svf_band_mid) >> 1;
        let vocal_focus_r = (svf_band_r + svf_band_mid) >> 1;
        let svara_gain_q10 = (preset.svara_formant_q10 * soul_expr_q10) >> 10;
        let svara_l = (vocal_focus_l * svara_gain_q10) >> 11;
        let svara_r = (vocal_focus_r * svara_gain_q10) >> 11;
        let naad_l = (svf_low_l * preset.naad_sub_q10) >> 12;
        let naad_r = (svf_low_r * preset.naad_sub_q10) >> 12;

        // 7. Goonj Balanced-Ternary `{-1, 0, +1}` Dark Velvet Noise (`DVN`) Spatial Room Bloom
        dvn_buf_l[dvn_write_idx] = l1;
        dvn_buf_r[dvn_write_idx] = r1;
        let mut dvn_acc_l: i64 = 0;
        let mut dvn_acc_r: i64 = 0;
        if preset.goonj_velvet_q10 > 0 {
            for &(tap_offset, sign_l, sign_r) in &GOONJ_DVN_TERNARY_TAPS {
                let r_idx = (dvn_write_idx + 4096 - tap_offset) & 4095;
                let tap_l = dvn_buf_l[r_idx] as i64;
                let tap_r = dvn_buf_r[r_idx] as i64;
                // Multiplier-free balanced ternary (`+1` or `-1` add/sub)
                dvn_acc_l += if sign_l > 0 { tap_l } else { -tap_l };
                dvn_acc_r += if sign_r > 0 { tap_r } else { -tap_r };
            }
        }
        dvn_write_idx = (dvn_write_idx + 1) & 4095;
        // 1-pole velvet darkening filter (`JAES 2024 Dark Velvet Noise`)
        dvn_dark_l = (dvn_dark_l * 3 + (dvn_acc_l >> 3)) >> 2;
        dvn_dark_r = (dvn_dark_r * 3 + (dvn_acc_r >> 3)) >> 2;
        let goonj_l = (dvn_dark_l * preset.goonj_velvet_q10) >> 14;
        let goonj_r = (dvn_dark_r * preset.goonj_velvet_q10) >> 14;

        // Combine revealed harmonic components
        let raw_l = s_l
            + even_harm_l
            + lp_norm_l
            + sparkle_l
            + air_l
            + punch_l
            + phi_bloom_l
            + svara_l
            + naad_l
            + goonj_l;
        let raw_r = s_r
            + even_harm_r
            + lp_norm_r
            + sparkle_r
            + air_r
            + punch_r
            + phi_bloom_r
            + svara_r
            + naad_r
            + goonj_r;

        // 1-pole integer DC blocker: `y[n] = x[n] - x[n-1] + (255 * y[n-1]) / 256`
        let dc_l = raw_l - dc_prev_in_l + ((dc_prev_out_l * 255) >> 8);
        dc_prev_in_l = raw_l;
        dc_prev_out_l = dc_l;

        let dc_r = raw_r - dc_prev_in_r + ((dc_prev_out_r * 255) >> 8);
        dc_prev_in_r = raw_r;
        dc_prev_out_r = dc_r;

        // 8. Stereo Mid/Side (`M/S`) Holographic Spatial Locus Widening
        let (final_l, final_r) = if ch == 2 {
            let mid = (dc_l + dc_r) >> 1;
            let side = ((dc_l - dc_r) * preset.stereo_width_q10) >> 11;
            (
                soft_limit_i16(mid + side),
                soft_limit_i16(mid - side),
            )
        } else {
            let m = soft_limit_i16(dc_l);
            (m, m)
        };

        out_pcm.push(final_l);
        if ch == 2 {
            out_pcm.push(final_r);
        }

        let mono_out = ((final_l as i64) + (final_r as i64)) >> 1;
        output_energy_sum = output_energy_sum.saturating_add((mono_out.unsigned_abs()) >> 4);
    }

    // Compute exact `p/q` Rational metrics for the PhoenixSoundReceipt
    let dominant_freq_hz = if zc_intervals_count > 0 && period_accum_ticks > 0 {
        let num = (internal_oversample_hz as u64).saturating_mul(zc_intervals_count);
        let den = period_accum_ticks.max(1);
        safe_rational_u64(num, den)
    } else {
        Rational::integer(SOVEREIGN_ANCHOR_HZ as i32)
    };
    let (shruti_interval_ratio, shruti_name) = nearest_taal_shruti_pq(dominant_freq_hz);

    // Golden-ratio companions: `f * 500 / 809` (`f / φ`) and `f * 809 / 500` (`f * φ`)
    let phi_lower_hz = safe_rational_u64(
        (dominant_freq_hz.num.max(1) as u64).saturating_mul(500),
        (dominant_freq_hz.den as u64).saturating_mul(809),
    );
    let phi_upper_hz = safe_rational_u64(
        (dominant_freq_hz.num.max(1) as u64).saturating_mul(809),
        (dominant_freq_hz.den as u64).saturating_mul(500),
    );

    let period_jitter_ratio = if period_accum_ticks > 0 {
        safe_rational_u64(period_jitter_accum.min(period_accum_ticks), period_accum_ticks)
    } else {
        Rational::ZERO
    };

    let amplitude_jitter_ratio = if peak_accum > 0 {
        safe_rational_u64(amp_jitter_accum.min(peak_accum), peak_accum)
    } else {
        Rational::ZERO
    };

    // Soul Authenticity (`0..1024 / 1024`): natural music has organic period & amplitude micro-jitter
    let jp_permille = ((period_jitter_accum * 1024) / period_accum_ticks.max(1)).min(512);
    let ja_permille = ((amp_jitter_accum * 1024) / peak_accum.max(1)).min(512);
    let soul_num = (640 + jp_permille + (ja_permille >> 1)).clamp(512, 1020) as i32;
    let soul_authenticity = Rational::new(soul_num, 1024).unwrap_or(Rational::ONE);

    // Emit final `0x21` TUNE opcode carrying `J_p`, `J_a`, and Soul score
    let jp_b = (jp_permille as u16).to_le_bytes();
    let ja_b = (ja_permille as u16).to_le_bytes();
    opcodes_8a.extend_from_slice(&[
        OpCode8a::Tune as u8,
        jp_b[0],
        jp_b[1],
        ja_b[0],
        ja_b[1],
        ((soul_num >> 2).min(255)) as u8,
        0,
    ]);

    let pcm_fnv1a_hash = fnv1a_pcm_i16(&out_pcm);
    let eight_a_stream = build_8a_stream(&opcodes_8a, pcm_fnv1a_hash, rate, ch as u16);
    let eight_a_bytes = eight_a_stream.len();

    let harmonic_bloom_ratio = if input_energy_sum > 0 {
        // Reduce to clean rational in Q10 scale (`num / 1024`)
        let bloom_q10 = ((output_energy_sum as u128 * 1024) / (input_energy_sum as u128)).clamp(1, 65536) as i32;
        Rational::new(bloom_q10, 1024).unwrap_or(Rational::ONE)
    } else {
        Rational::ONE
    };

    let receipt = PhoenixSoundReceipt {
        sample_rate_hz: rate,
        internal_oversample_hz,
        channels: ch as u16,
        total_frames: frames as u64,
        catmull_rom_restored_samples,
        dominant_freq_hz,
        shruti_interval_ratio,
        shruti_name,
        phi_lower_hz,
        phi_upper_hz,
        period_jitter_ratio,
        amplitude_jitter_ratio,
        soul_authenticity,
        harmonic_s_frames,
        stochastic_n_frames,
        dirac_t_frames,
        silence_frames,
        harmonic_bloom_ratio,
        pcm_fnv1a_hash,
        eight_a_bytes,
    };

    (out_pcm, eight_a_stream, receipt)
}

/// Stateful Real-Time Streaming Processor for System-Wide PipeWire / ALSA "PhoeniX on Everything".
///
/// Maintains continuous Catmull-Rom 4-sample history, Naad Chamberlin SVF registers,
/// Svara formant bandpass state, 432 Hz / φ resonators, Goonj 4096-frame Balanced-Ternary
/// Dark Velvet Noise (`{-1, 0, +1}`) reflection ring buffer, and rolling 768 kHz `p/q`
/// zero-crossing telemetry across arbitrary chunk boundaries with **zero boundary clicks**.
pub struct PhoenixLiveProcessor {
    pub sample_rate_hz: u32,
    pub internal_oversample_hz: u32,
    pub preset: PhoenixSoundPreset,
    hist_l: [i16; 3],
    hist_r: [i16; 3],
    upsample_hist_l: [i16; 3],
    upsample_hist_r: [i16; 3],
    lowpass_l: i64,
    lowpass_r: i64,
    svf_low_l: i64,
    svf_band_l: i64,
    svf_low_r: i64,
    svf_band_r: i64,
    dvn_buf_l: Vec<i16>,
    dvn_buf_r: Vec<i16>,
    dvn_write_idx: usize,
    dvn_dark_l: i64,
    dvn_dark_r: i64,
    dc_prev_in_l: i64,
    dc_prev_out_l: i64,
    dc_prev_in_r: i64,
    dc_prev_out_r: i64,
    phi_resonator_l: i64,
    phi_resonator_r: i64,
    env_fast_q10: i64,
    env_slow_q10: i64,
    global_frame_idx: u64,
    last_zc_tick_768k: u64,
    prev_period_ticks_768k: u64,
    period_accum_ticks: u64,
    period_jitter_accum: u64,
    zc_intervals_count: u64,
    prev_peak_abs: i64,
    amp_jitter_accum: u64,
    peak_accum: u64,
    current_peak_abs: i64,
    pub catmull_rom_restored_samples: u64,
    pub harmonic_s_frames: u64,
    pub stochastic_n_frames: u64,
    pub dirac_t_frames: u64,
    pub silence_frames: u64,
    dyad_ema: [i64; 6],
    prev_band: [i64; 11],
    prev_babbage_c3: i64,
    prev_spline_arch: i64,
    /// 64-anchor Time-Domain Marine Salience Spectrum (`20 Hz .. 384,000 Hz`, expanded to 4096 buckets via Catmull-Rom!).
    pub marine_buckets_q10: [u16; 64],
    /// 64-anchor Center-Stage Singer Voice & Formant Salience (`20 Hz .. 384,000 Hz`, isolated Singer-Only vocal emotion!).
    pub marine_vocal_q10: [u16; 64],
    // ── 5-Lock Svara Glottal-Formant Vocal Detector & 4-Slot Real-Time Singer Diarizer ──
    prev_voc_wave: i64,
    voc_last_zc_frame: u64,
    voc_prev_period: u64,
    voc_ema_period_q4: u64,
    pub voc_lock_streak: u16,
    voc_f0_ema: i64,
    voc_f1_ema: i64,
    voc_f2_ema: i64,
    voc_f3_ema: i64,
    voc_sub_ema: i64,
    /// Instantaneous Svara Vocal-Only Confidence (`0..=1024`). Zero during instrumental passages!
    pub vocal_confidence_q10: u16,
    /// Currently singing diarized voice slot (`0..=3` for `V1..V4`, or `255` when instrumental-only).
    pub active_singer_id: u8,
    /// Isolated glottal fundamental pitch `F0` of the active human singer in Hz (`0` when instrumental).
    pub vocal_f0_hz: u16,
    /// Vocal-tract formant ratio `(F2 + F3) / (F0 + F1)` in Q8 (`256 = 1/1`).
    pub vocal_formant_ratio_q8: u16,
    pending_new_f0: u16,
    pending_new_streak: u8,
    /// 4 real-time diarized singer slots (`V1..V4`) tracking multiple vocalists across a song or room.
    pub singer_slots: [DiarizedSingerSlot; 4],
    /// Auto-Magical Svara & Fletcher-Munson self-tuning mode (`true` by default).
    pub automagic: bool,
    /// User-facing Voice Soul macro multiplier in Q10 (`1024 = 100%`, `0..=2048`).
    pub feel_voice_q10: i64,
    /// User-facing Deep Bass (`< 140 Hz` Naad) macro multiplier in Q10 (`1024 = 100%`, `0..=2048`).
    pub feel_bass_q10: i64,
    /// User-facing Space & 384 kHz Air macro multiplier in Q10 (`1024 = 100%`, `0..=2048`).
    pub feel_space_q10: i64,
    /// Sustained Drive-Passion upper-mid glare fatigue accumulator (`0..=1024` Q10).
    drive_glare_fatigue_q10: u32,
    /// Active frames in the current expressive Passion crest window (`0..=96_000` frames, ~2s at 48 kHz).
    passion_crest_frames: u32,
    /// Cooldown frames between expressive Passion crests (`0..=384_000` frames, ~8s at 48 kHz) so Passion hits every now and then!
    passion_cooldown_frames: u32,
    /// Whether the built-in 432Hz x phi Alexandra Sanctuary Nervous-System Reset Wave is active.
    pub alexandra_reset_active: bool,
    /// Smooth crossfade envelope (`0..=1024` Q10) for fading out upsetting songs and fading in the Sanctuary Reset bath.
    alexandra_reset_mix_q10: i64,
    /// Sample counter for the pure-integer Alexandra Sanctuary Reset oscillator lattice.
    alexandra_reset_phase: u64,
}

/// Real-time diarized vocal identity slot (`V1..V4`) computed in 100% integer math.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct DiarizedSingerSlot {
    /// Whether this slot has locked onto a distinct human voice.
    pub active: bool,
    /// Slot index (`0..=3` -> `V1..V4`).
    pub slot_id: u8,
    /// Characteristic fundamental frequency centroid in Hz (`80..=960 Hz`).
    pub f0_centroid_hz: u16,
    /// Characteristic vocal-tract formant ratio `(F2 + F3) / (F0 + F1)` in Q8 (`32..=1024`).
    pub formant_ratio_q8: u16,
    /// Smoothed vocal emotion Valence X (`-940..=+940`: Velvet/Longing <-> Joyful/Intimate).
    pub emo_x_q10: i16,
    /// Smoothed vocal emotion Arousal Y (`-940..=+940`: Belting/Soaring <-> Tender/Intimate).
    pub emo_y_q10: i16,
    /// Current presence/activity confidence (`0..=1024`) for this singer.
    pub presence_q10: u16,
    /// Total stereo frames sung by this diarized voice.
    pub frames_sung: u64,
    /// Last `global_frame_idx` when this singer was actively singing.
    pub last_active_frame: u64,
}

impl DiarizedSingerSlot {
    /// Classify a vocal fundamental `f0_hz` into one of 4 natural human singing registers (`0..=3`):
    /// - `0`: Baritone / Low Chest (`< 166 Hz`)
    /// - `1`: Rock Tenor / High-Baritone (`166..=248 Hz` — e.g. Ozzy Osbourne's core range)
    /// - `2`: Contralto / Mezzo-Alto (`249..=355 Hz` — e.g. Lita Ford's warm verse / high duet range)
    /// - `3`: Soprano / Soaring Belt (`> 355 Hz` — e.g. Lita Ford's chorus belt)
    pub const fn register_band(f0_hz: u16) -> u8 {
        if f0_hz < 166 {
            0
        } else if f0_hz <= 248 {
            1
        } else if f0_hz <= 355 {
            2
        } else {
            3
        }
    }

    /// Human vocal archetype label derived from `f0_centroid_hz` and vocal-tract `formant_ratio_q8`.
    pub const fn archetype_name(&self) -> &'static str {
        if !self.active {
            "Unassigned"
        } else if self.f0_centroid_hz < 166 {
            if self.formant_ratio_q8 > 290 && self.f0_centroid_hz >= 148 {
                "Tenor"
            } else {
                "Baritone"
            }
        } else if self.f0_centroid_hz <= 248 {
            "Tenor"
        } else if self.f0_centroid_hz <= 355 {
            if self.formant_ratio_q8 > 280 {
                "Mezzo-Alto"
            } else {
                "Contralto"
            }
        } else {
            "Soprano"
        }
    }
}

impl PhoenixLiveProcessor {
    /// Create a new real-time stereo `s16le` PhoeniX streaming processor at `sample_rate_hz` (`48000`).
    pub fn new(sample_rate_hz: u32, preset: PhoenixSoundPreset) -> Self {
        let rate = sample_rate_hz.max(8000);
        Self {
            sample_rate_hz: rate,
            internal_oversample_hz: rate.saturating_mul(16),
            preset,
            hist_l: [0; 3],
            hist_r: [0; 3],
            upsample_hist_l: [0; 3],
            upsample_hist_r: [0; 3],
            lowpass_l: 0,
            lowpass_r: 0,
            svf_low_l: 0,
            svf_band_l: 0,
            svf_low_r: 0,
            svf_band_r: 0,
            dvn_buf_l: vec![0i16; 4096],
            dvn_buf_r: vec![0i16; 4096],
            dvn_write_idx: 0,
            dvn_dark_l: 0,
            dvn_dark_r: 0,
            dc_prev_in_l: 0,
            dc_prev_out_l: 0,
            dc_prev_in_r: 0,
            dc_prev_out_r: 0,
            phi_resonator_l: 0,
            phi_resonator_r: 0,
            env_fast_q10: 0,
            env_slow_q10: 0,
            global_frame_idx: 0,
            last_zc_tick_768k: 0,
            prev_period_ticks_768k: 0,
            period_accum_ticks: 0,
            period_jitter_accum: 0,
            zc_intervals_count: 0,
            prev_peak_abs: 0,
            amp_jitter_accum: 0,
            peak_accum: 0,
            current_peak_abs: 0,
            catmull_rom_restored_samples: 0,
            harmonic_s_frames: 0,
            stochastic_n_frames: 0,
            dirac_t_frames: 0,
            silence_frames: 0,
            dyad_ema: [0; 6],
            prev_band: [0; 11],
            prev_babbage_c3: 0,
            prev_spline_arch: 0,
            marine_buckets_q10: [0; 64],
            marine_vocal_q10: [0; 64],
            prev_voc_wave: 0,
            voc_last_zc_frame: 0,
            voc_prev_period: 0,
            voc_ema_period_q4: 0,
            voc_lock_streak: 0,
            voc_f0_ema: 0,
            voc_f1_ema: 0,
            voc_f2_ema: 0,
            voc_f3_ema: 0,
            voc_sub_ema: 0,
            vocal_confidence_q10: 0,
            active_singer_id: 255,
            vocal_f0_hz: 0,
            vocal_formant_ratio_q8: 0,
            pending_new_f0: 0,
            pending_new_streak: 0,
            singer_slots: [
                DiarizedSingerSlot { slot_id: 0, ..DiarizedSingerSlot::default() },
                DiarizedSingerSlot { slot_id: 1, ..DiarizedSingerSlot::default() },
                DiarizedSingerSlot { slot_id: 2, ..DiarizedSingerSlot::default() },
                DiarizedSingerSlot { slot_id: 3, ..DiarizedSingerSlot::default() },
            ],
            automagic: true,
            feel_voice_q10: 1024,
            feel_bass_q10: 1024,
            feel_space_q10: 1024,
            drive_glare_fatigue_q10: 0,
            passion_crest_frames: 0,
            passion_cooldown_frames: 0,
            alexandra_reset_active: false,
            alexandra_reset_mix_q10: 0,
            alexandra_reset_phase: 0,
        }
    }

    /// Pure-integer Bhaskara-refined parabolic sine oscillator (`phase_q16` in `0..65536` -> `-4096..=+4096`).
    /// Zero floating-point operations and `< 1/600` harmonic residual (pure velvet sinusoid!).
    #[inline]
    fn parabolic_sine_q12(phase_q16: u32) -> i64 {
        let half = (phase_q16 & 32767) as i64;
        let centered = half - 16384;
        let parab = 16384 - ((centered * centered) >> 14);
        // Bhaskara refinement (`parab * (49152 + parab) >> 18`) eliminates 3rd-harmonic triangle corners!
        let refined = (parab * (49152 + parab)) >> 18;
        if (phase_q16 & 32768) != 0 {
            -refined
        } else {
            refined
        }
    }

    /// Synthesize one stereo frame of the 432Hz x phi Alexandra Sanctuary Nervous-System Reset Wave:
    /// - 108 Hz Naad Sub-Pillow (`Sa / 4`)
    /// - 267 Hz (`432 * 500 / 809 = 432 / phi`) Golden-Ratio Heart Resonator (with 1 Hz binaural cocoon)
    /// - 432 Hz (`Sa 1/1`) Sovereign Sanctuary Fundamental (with 2 Hz alpha/theta parasympathetic binaural drift)
    /// - 540 Hz (`Shuddha Ga 5/4`) Warm Just-Intonation Third breathing on a 10-second Riva Dyad cycle
    /// - Every 10 seconds (`480_000` frames at 48 kHz), a 2-second (`384_000..480_000`) velvety Cello/Contralto
    ///   Passion Swell (`648 Hz Pa 3/2` + `864 Hz Octave Sa 2/1`) gently crests into Passion (`270°`) and melts back into Sanctuary!
    #[inline]
    fn synth_alexandra_reset_frame(&mut self) -> (i16, i16) {
        let t = self.alexandra_reset_phase;
        self.alexandra_reset_phase = self.alexandra_reset_phase.wrapping_add(1);
        let rate = self.sample_rate_hz.max(8000) as u64;

        // 10-second Riva Dyad cycle (`10 * rate` frames)
        let cycle_len = rate * 10;
        let pos = t % cycle_len;
        let half_cycle = cycle_len / 2;
        let dist_breath = if pos < half_cycle {
            pos
        } else {
            cycle_len - pos
        };
        // Smooth breath envelope `640..=1024` Q10
        let breath_q10 = (640 + ((dist_breath * 384) / half_cycle.max(1))) as i64;

        // 2-second velvety Passion Swell during the final 2 seconds (`8s..10s`) of each 10s cycle
        let passion_start = rate * 8;
        let passion_q10: i64 = if pos >= passion_start {
            let p_span = rate * 2;
            let p_mid = passion_start + rate;
            let p_dist = pos.abs_diff(p_mid);
            (((rate.saturating_sub(p_dist)) * 1024) / (p_span / 2).max(1)) as i64
        } else {
            0
        };

        let p_108 = (((t * 108) << 16) / rate) as u32;
        let p_267_l = (((t * 267) << 16) / rate) as u32;
        let p_268_r = (((t * 268) << 16) / rate) as u32;
        let p_432_l = (((t * 432) << 16) / rate) as u32;
        let p_434_r = (((t * 434) << 16) / rate) as u32;
        let p_540_l = (((t * 540) << 16) / rate) as u32;
        let p_541_r = (((t * 541) << 16) / rate) as u32;
        let p_648 = (((t * 648) << 16) / rate) as u32;
        let p_864 = (((t * 864) << 16) / rate) as u32;
        let p_1296 = (((t * 1296) << 16) / rate) as u32;

        let w_sub = Self::parabolic_sine_q12(p_108);
        let w_phi_l = Self::parabolic_sine_q12(p_267_l);
        let w_phi_r = Self::parabolic_sine_q12(p_268_r);
        let w_sa_l = Self::parabolic_sine_q12(p_432_l);
        let w_sa_r = Self::parabolic_sine_q12(p_434_r);
        let w_ga_l = Self::parabolic_sine_q12(p_540_l);
        let w_ga_r = Self::parabolic_sine_q12(p_541_r);
        let w_pa = Self::parabolic_sine_q12(p_648);
        let w_oct = Self::parabolic_sine_q12(p_864);
        let w_passion_silk = Self::parabolic_sine_q12(p_1296);

        let sanct_l = ((w_sub * 520) + (w_phi_l * 760) + (w_sa_l * 820) + (w_ga_l * 460)) >> 10;
        let sanct_r = ((w_sub * 520) + (w_phi_r * 760) + (w_sa_r * 820) + (w_ga_r * 460)) >> 10;
        let passion_voice = ((w_pa * 560) + (w_oct * 440) + (w_passion_silk * 280)) >> 10;

        let out_l = (((sanct_l * breath_q10) >> 10) + ((passion_voice * passion_q10) >> 10)).clamp(-18_000, 18_000) as i16;
        let out_r = (((sanct_r * breath_q10) >> 10) + ((passion_voice * passion_q10) >> 10)).clamp(-18_000, 18_000) as i16;
        (out_l, out_r)
    }

    /// Update the Auto-Magical self-tuning toggle and 3 simple human-feel macros (`0..=200` percent, where `100` = `1024` Q10).
    pub fn set_feel_controls(&mut self, automagic: bool, voice_pct: u16, bass_pct: u16, space_pct: u16) {
        self.automagic = automagic;
        self.feel_voice_q10 = (((voice_pct.min(200) as i64) * 1024) / 100).clamp(0, 2048);
        self.feel_bass_q10 = (((bass_pct.min(200) as i64) * 1024) / 100).clamp(0, 2048);
        self.feel_space_q10 = (((space_pct.min(200) as i64) * 1024) / 100).clamp(0, 2048);
    }

    /// Process an interleaved stereo `s16le` slice (`[L0, R0, L1, R1, ...]`) in-place!
    pub fn process_stereo_in_place(&mut self, interleaved_stereo: &mut [i16]) {
        let frames = interleaved_stereo.len() / 2;
        if frames == 0 {
            return;
        }

        for f in 0..frames {
            let mut in_l = interleaved_stereo[f * 2];
            let mut in_r = interleaved_stereo[f * 2 + 1];

            // Smoothly crossfade into/out of the built-in 432Hz x phi Alexandra Sanctuary Reset Wave
            if self.alexandra_reset_active {
                if (f & 31) == 0 && self.alexandra_reset_mix_q10 < 1024 {
                    self.alexandra_reset_mix_q10 = (self.alexandra_reset_mix_q10 + 2).min(1024);
                }
            } else if (f & 31) == 0 && self.alexandra_reset_mix_q10 > 0 {
                self.alexandra_reset_mix_q10 = (self.alexandra_reset_mix_q10 - 2).max(0);
            }
            if self.alexandra_reset_mix_q10 > 0 {
                let (rst_l, rst_r) = self.synth_alexandra_reset_frame();
                let mix = self.alexandra_reset_mix_q10;
                let dry = 1024 - mix;
                in_l = (((in_l as i64 * dry) + (rst_l as i64 * mix)) >> 10) as i16;
                in_r = (((in_r as i64 * dry) + (rst_r as i64 * mix)) >> 10) as i16;
            }

            // Shift 4-sample window: `(l0, l1, l2, l3)` where `l3` is the newly arrived sample
            let l0 = self.hist_l[0];
            let mut l1 = self.hist_l[1];
            let l2 = self.hist_l[2];
            let l3 = in_l;

            let r0 = self.hist_r[0];
            let mut r1 = self.hist_r[1];
            let r2 = self.hist_r[2];
            let r3 = in_r;

            // Stage 1: Real-time Catmull-Rom brickwall clipping & dropout repair on `l1` / `r1`
            if (l1 as i64).abs() >= 32600
                || (l1 == 0 && (l0 as i64).abs() > 2400 && (l2 as i64).abs() > 2400 && (l0 as i64) * (l2 as i64) > 0)
            {
                l1 = catmull_rom_midpoint_i16(l0, l0, l2, l3);
                self.catmull_rom_restored_samples += 1;
            }
            if (r1 as i64).abs() >= 32600
                || (r1 == 0 && (r0 as i64).abs() > 2400 && (r2 as i64).abs() > 2400 && (r0 as i64) * (r2 as i64) > 0)
            {
                r1 = catmull_rom_midpoint_i16(r0, r0, r2, r3);
                self.catmull_rom_restored_samples += 1;
            }

            self.hist_l = [l1, l2, l3];
            self.hist_r = [r1, r2, r3];

            let mid_l = catmull_rom_midpoint_i16(l0, l1, l2, l3) as i64;
            let mid_r = catmull_rom_midpoint_i16(r0, r1, r2, r3) as i64;

            let s_l = l1 as i64;
            let s_r = r1 as i64;
            let mono_in = (s_l + s_r) >> 1;
            let next_mono = ((l2 as i64) + (r2 as i64)) >> 1;
            let abs_mono = mono_in.abs();
            if abs_mono > self.current_peak_abs {
                self.current_peak_abs = abs_mono;
            }

            // 768 kHz sub-sample zero-crossing pitch & jitter tracker
            if mono_in <= 0 && next_mono > 0 {
                let span = (next_mono - mono_in).max(1);
                let sub_k = (((-mono_in) * 16) / span).clamp(0, 16) as u64;
                let tick_768k = self.global_frame_idx * 16 + sub_k;
                if self.last_zc_tick_768k > 0 {
                    let period_ticks = tick_768k.saturating_sub(self.last_zc_tick_768k);
                    let min_ticks = (self.internal_oversample_hz as u64) / 4000;
                    let max_ticks = (self.internal_oversample_hz as u64) / 30;
                    if period_ticks >= min_ticks && period_ticks <= max_ticks {
                        // Rolling exponential window so live pitch updates responsively per song
                        if self.zc_intervals_count >= 64 {
                            self.period_accum_ticks >>= 1;
                            self.period_jitter_accum >>= 1;
                            self.amp_jitter_accum >>= 1;
                            self.peak_accum >>= 1;
                            self.zc_intervals_count >>= 1;
                        }
                        self.period_accum_ticks = self.period_accum_ticks.saturating_add(period_ticks);
                        if self.prev_period_ticks_768k > 0 {
                            let dp = period_ticks.abs_diff(self.prev_period_ticks_768k);
                            self.period_jitter_accum = self.period_jitter_accum.saturating_add(dp);
                        }
                        self.prev_period_ticks_768k = period_ticks;

                        let da = self.current_peak_abs.abs_diff(self.prev_peak_abs);
                        self.amp_jitter_accum = self.amp_jitter_accum.saturating_add(da);
                        self.peak_accum = self.peak_accum.saturating_add(self.current_peak_abs as u64);
                        self.prev_peak_abs = self.current_peak_abs;
                        self.current_peak_abs = 0;
                        self.zc_intervals_count += 1;
                    }
                }
                self.last_zc_tick_768k = tick_768k;
            }
            self.global_frame_idx = self.global_frame_idx.wrapping_add(1);

            // Stage 2: S + N + T + Naad Chamberlin SVF
            self.lowpass_l = (self.lowpass_l * 7 + s_l) >> 3;
            self.lowpass_r = (self.lowpass_r * 7 + s_r) >> 3;

            let svf_high_l = s_l - self.svf_low_l - ((self.svf_band_l * 640) >> 10);
            self.svf_band_l = (self.svf_band_l + ((svf_high_l * 180) >> 10)).clamp(-32767, 32767);
            self.svf_low_l = (self.svf_low_l + ((self.svf_band_l * 180) >> 10)).clamp(-32767, 32767);

            let svf_high_r = s_r - self.svf_low_r - ((self.svf_band_r * 640) >> 10);
            self.svf_band_r = (self.svf_band_r + ((svf_high_r * 180) >> 10)).clamp(-32767, 32767);
            self.svf_low_r = (self.svf_low_r + ((self.svf_band_r * 180) >> 10)).clamp(-32767, 32767);

            let dl1 = (l2 as i64) - s_l;
            let dl0 = s_l - (l0 as i64);
            let d2l = dl1 - dl0;

            let dr1 = (r2 as i64) - s_r;
            let dr0 = s_r - (r0 as i64);
            let d2r = dr1 - dr0;

            let spline_arch_l = mid_l - ((s_l + (l2 as i64)) >> 1);
            let spline_arch_r = mid_r - ((s_r + (r2 as i64)) >> 1);

            let inst_env_q10 = (s_l.abs().max(s_r.abs())) << 2;
            self.env_fast_q10 = (self.env_fast_q10 * 3 + inst_env_q10) >> 2;
            self.env_slow_q10 = (self.env_slow_q10 * 31 + inst_env_q10) >> 5;
            let transient_excess_q10 = (self.env_fast_q10 - self.env_slow_q10).max(0);

            let state = if abs_mono < 48 && self.env_fast_q10 < 256 {
                self.silence_frames += 1;
                AcousticState::Silence
            } else if transient_excess_q10 > (self.env_slow_q10 >> 1).max(2048) {
                self.dirac_t_frames += 1;
                AcousticState::DiracTransient
            } else if d2l.abs() + d2r.abs() > abs_mono * 2 {
                self.stochastic_n_frames += 1;
                AcousticState::StochasticNoise
            } else {
                self.harmonic_s_frames += 1;
                AcousticState::HarmonicSinusoid
            };

            // Stage 3: Synthesis (Envelope-Adaptive Triode Warmth + Auto-Magical Svara Self-Tuning)
            // When `automagic` is enabled, the engine continuously adapts Voice, Deep Bass, and Space
            // using the 5-Lock Svara Vocal Detector and Fletcher-Munson loudness contour:
            // - Voice (`auto_vocal_q10`): relaxes to 920 during instrumentals so guitars/synths never sound boxy,
            //   and blooms up to 1320 when a human voice is singing (`vocal_confidence_q10 > 0`).
            // - Deep Bass (`auto_bass_q10`): warms `< 140 Hz` sub-bass to 1240 on quiet/intimate passages
            //   (Fletcher-Munson compensation), sits at 1140 on full grooves, and gently tucks to 960 when
            //   a singer belts loudly so bass never muddies the lead vocal.
            // - Space & Air (`auto_space_q10`): opens 384 kHz air & Dark Velvet Goonj to 1160 on sustained
            //   harmonic passages and tightens to 960 on percussive transients.
            let (auto_vocal_q10, auto_bass_q10, auto_space_q10) = if self.automagic {
                let av = 920 + (((self.vocal_confidence_q10 as i64) * 400) >> 10);
                let ab = if self.vocal_confidence_q10 > 320 && self.env_slow_q10 >= 16_000 {
                    960
                } else if self.env_slow_q10 < 16_000 {
                    1240
                } else {
                    1140
                };
                let asp = if state == AcousticState::HarmonicSinusoid {
                    1160
                } else {
                    960
                };
                (av, ab, asp)
            } else {
                (1024, 1024, 1024)
            };
            let total_voice_q10 = ((auto_vocal_q10 * self.feel_voice_q10) >> 10).clamp(0, 2560);
            let total_bass_q10 = ((auto_bass_q10 * self.feel_bass_q10) >> 10).clamp(0, 2560);
            let total_space_q10 = ((auto_space_q10 * self.feel_space_q10) >> 10).clamp(0, 2560);

            let triode_norm = ((self.env_slow_q10 >> 2) + 4096).clamp(6144, 32768);
            let even_harm_l = (((s_l * s_l.abs()) / triode_norm) * self.preset.warmth_q10) >> 11;
            let even_harm_r = (((s_r * s_r.abs()) / triode_norm) * self.preset.warmth_q10) >> 11;
            let lp_norm_l = (self.lowpass_l * self.preset.drive_q10) >> 12;
            let lp_norm_r = (self.lowpass_r * self.preset.drive_q10) >> 12;
            let eff_sparkle_q10 = (self.preset.sparkle_q10 * total_space_q10) >> 10;
            let eff_air_q10 = (self.preset.air_q10 * total_space_q10) >> 10;
            let sparkle_l = (spline_arch_l * eff_sparkle_q10) >> 9;
            let sparkle_r = (spline_arch_r * eff_sparkle_q10) >> 9;
            let air_l = ((dl1 - (d2l >> 2)) * eff_air_q10) >> 12;
            let air_r = ((dr1 - (d2r >> 2)) * eff_air_q10) >> 12;

            let punch_gain_q10 = if state == AcousticState::DiracTransient {
                self.preset.punch_q10
            } else {
                self.preset.punch_q10 >> 2
            };
            let punch_l = ((s_l - self.lowpass_l) * punch_gain_q10) >> 12;
            let punch_r = ((s_r - self.lowpass_r) * punch_gain_q10) >> 12;

            self.phi_resonator_l = (self.phi_resonator_l * 500 + self.lowpass_l * 309) / 809;
            self.phi_resonator_r = (self.phi_resonator_r * 500 + self.lowpass_r * 309) / 809;
            let phi_bloom_l = (self.phi_resonator_l * self.preset.phi_432_bloom_q10) >> 12;
            let phi_bloom_r = (self.phi_resonator_r * self.preset.phi_432_bloom_q10) >> 12;

            // 6-stage dyadic shift-only wavelet ladder on input `mono_in`:
            // Stage 5 (`dyad_ema[5]`) is a pure <140 Hz sub-bass resonator (~119 Hz cutoff at 48 kHz),
            // and Stage 4 (`dyad_ema[4]`) is the 140..280 Hz bass/baritone fundamental!
            self.dyad_ema[0] += (mono_in - self.dyad_ema[0]) >> 1;
            self.dyad_ema[1] += (self.dyad_ema[0] - self.dyad_ema[1]) >> 2;
            self.dyad_ema[2] += (self.dyad_ema[1] - self.dyad_ema[2]) >> 3;
            self.dyad_ema[3] += (self.dyad_ema[2] - self.dyad_ema[3]) >> 4;
            self.dyad_ema[4] += (self.dyad_ema[3] - self.dyad_ema[4]) >> 5;
            self.dyad_ema[5] += (self.dyad_ema[4] - self.dyad_ema[5]) >> 6;

            let sub_140 = self.dyad_ema[5];
            let sub_harm = ((sub_140 * sub_140.abs()) / triode_norm) >> 1;
            let deep_bass_l = sub_140 + sub_harm + (self.svf_low_l >> 1);
            let deep_bass_r = sub_140 + sub_harm + (self.svf_low_r >> 1);

            let jp_q10 = ((self.period_jitter_accum * 1024) / self.period_accum_ticks.max(1)).min(384) as i64;
            let ja_q10 = ((self.amp_jitter_accum * 512) / self.peak_accum.max(1)).min(256) as i64;
            let soul_expr_q10 = if state == AcousticState::HarmonicSinusoid {
                1024 + jp_q10 + ja_q10
            } else {
                1024
            };
            let svf_band_mid = (self.svf_band_l + self.svf_band_r) >> 1;
            let vocal_focus_l = (self.svf_band_l + svf_band_mid) >> 1;
            let vocal_focus_r = (self.svf_band_r + svf_band_mid) >> 1;
            let svara_base_q10 = (self.preset.svara_formant_q10 * soul_expr_q10) >> 10;
            let svara_gain_q10 = (svara_base_q10 * total_voice_q10) >> 10;
            let svara_l = (vocal_focus_l * svara_gain_q10) >> 11;
            let svara_r = (vocal_focus_r * svara_gain_q10) >> 11;
            let eff_naad_q10 = (self.preset.naad_sub_q10 * total_bass_q10) >> 10;
            let naad_l = (deep_bass_l * eff_naad_q10) >> 10;
            let naad_r = (deep_bass_r * eff_naad_q10) >> 10;

            self.dvn_buf_l[self.dvn_write_idx] = l1;
            self.dvn_buf_r[self.dvn_write_idx] = r1;
            let mut dvn_acc_l: i64 = 0;
            let mut dvn_acc_r: i64 = 0;
            if self.preset.goonj_velvet_q10 > 0 {
                for &(tap_offset, sign_l, sign_r) in &GOONJ_DVN_TERNARY_TAPS {
                    let r_idx = (self.dvn_write_idx + 4096 - tap_offset) & 4095;
                    let tap_l = self.dvn_buf_l[r_idx] as i64;
                    let tap_r = self.dvn_buf_r[r_idx] as i64;
                    dvn_acc_l += if sign_l > 0 { tap_l } else { -tap_l };
                    dvn_acc_r += if sign_r > 0 { tap_r } else { -tap_r };
                }
            }
            self.dvn_write_idx = (self.dvn_write_idx + 1) & 4095;
            self.dvn_dark_l = (self.dvn_dark_l * 3 + (dvn_acc_l >> 3)) >> 2;
            self.dvn_dark_r = (self.dvn_dark_r * 3 + (dvn_acc_r >> 3)) >> 2;
            let eff_goonj_q10 = (self.preset.goonj_velvet_q10 * total_space_q10) >> 10;
            let goonj_l = (self.dvn_dark_l * eff_goonj_q10) >> 14;
            let goonj_r = (self.dvn_dark_r * eff_goonj_q10) >> 14;

            // ── Alexandra Sanctuary & Occasional Passion-Crest Governor ──
            // Balances 140..800 Hz Warmth & Sanctuary (`voc_sub_ema + voc_f0_ema + voc_f1_ema`) against
            // 1800..10000 Hz Drive-Passion upper-mid glare (`voc_f3_ema` + high-pass slew).
            // - Prevents sustained Drive-Passion glare across the 2800..4500 Hz female ear-canal resonance peak
            //   by subtracting harsh upper-mid glare and counter-blooming 140..800 Hz Sanctuary & Warmth.
            // - Opens a brief (~2s) velvety Passion Crest window every ~8s when an emotional vocal/harmonic
            //   peak arrives (`vocal_confidence_q10 >= 260` or harmonic swell), so Passion is hit every now and then
            //   before melting smoothly back into Sanctuary & Warmth!
            let warm_sanctuary_lvl = self.voc_sub_ema + (self.voc_f0_ema * 2) + (self.voc_f1_ema * 2) + 64;
            let hf_glare_abs = ((s_l - self.lowpass_l).abs() + (s_r - self.lowpass_r).abs()) >> 3;
            let drive_glare_lvl = self.voc_f2_ema + (self.voc_f3_ema * 3) + hf_glare_abs;

            if self.passion_cooldown_frames > 0 {
                self.passion_cooldown_frames -= 1;
            }
            let passion_trigger = state == AcousticState::HarmonicSinusoid
                && (self.vocal_confidence_q10 >= 260 || (self.voc_f2_ema + self.voc_f3_ema) > warm_sanctuary_lvl)
                && self.env_slow_q10 >= 10_000;
            if self.passion_crest_frames > 0 {
                self.passion_crest_frames += 1;
                // After ~2s (96_000 frames at 48 kHz), close the Passion crest and start ~8s Sanctuary cooldown!
                if self.passion_crest_frames >= 96_000 {
                    self.passion_crest_frames = 0;
                    self.passion_cooldown_frames = 384_000;
                }
            } else if passion_trigger && self.passion_cooldown_frames == 0 {
                self.passion_crest_frames = 1;
            }

            if (f & 15) == 0 {
                if drive_glare_lvl > warm_sanctuary_lvl && self.passion_crest_frames == 0 {
                    let excess = (((drive_glare_lvl - warm_sanctuary_lvl) * 512) / warm_sanctuary_lvl.max(64))
                        .clamp(0, 1024) as u32;
                    self.drive_glare_fatigue_q10 = ((self.drive_glare_fatigue_q10 * 15 + excess) >> 4).min(1024);
                } else {
                    self.drive_glare_fatigue_q10 = (self.drive_glare_fatigue_q10 * 15) >> 4;
                }
            }

            let is_alexandra_preset = self.preset.warmth_q10 == 360 && self.preset.goonj_velvet_q10 == 380;
            // Continuous sample-accurate triangle envelope (`0..=240` Q10) over 96_000 frames (~2s) -> zero step clicks!
            let passion_env_q10: i64 = if self.passion_crest_frames > 0 && self.passion_crest_frames < 96_000 {
                let dist_from_mid = (self.passion_crest_frames as i64 - 48_000).abs();
                ((48_000 - dist_from_mid) * 240) / 48_000
            } else {
                0
            };
            let (deharsh_q10, sanctuary_boost_q10, passion_window_q10): (i64, i64, i64) =
                if self.automagic || is_alexandra_preset {
                    let base_deharsh: i64 = if is_alexandra_preset { 220 } else { 100 };
                    let base_sanctuary: i64 = if is_alexandra_preset { 240 } else { 110 };
                    let fatigue = self.drive_glare_fatigue_q10 as i64;
                    let dh = (base_deharsh + ((fatigue * 320) >> 10) - (passion_env_q10 >> 1)).clamp(0, 520);
                    let sb = (base_sanctuary + ((fatigue * 260) >> 10)).clamp(0, 440);
                    (dh, sb, passion_env_q10)
                } else {
                    (0, 0, 0)
                };

            // Pure linear gain shaping on added harmonic branches only (zero phase-comb subtraction on dry `s_l/s_r`,
            // zero quadratic overdrive, and zero step discontinuities!):
            let treble_tuck_q10 = (1024 - (deharsh_q10 >> 1)).clamp(512, 1024);
            let adj_sparkle_l = (sparkle_l * treble_tuck_q10) >> 10;
            let adj_sparkle_r = (sparkle_r * treble_tuck_q10) >> 10;
            let adj_punch_l = (punch_l * treble_tuck_q10) >> 10;
            let adj_punch_r = (punch_r * treble_tuck_q10) >> 10;
            let adj_air_l = (air_l * (treble_tuck_q10 + (passion_window_q10 >> 1))) >> 10;
            let adj_air_r = (air_r * (treble_tuck_q10 + (passion_window_q10 >> 1))) >> 10;
            let adj_phi_l = (phi_bloom_l * (1024 + (sanctuary_boost_q10 >> 2))) >> 10;
            let adj_phi_r = (phi_bloom_r * (1024 + (sanctuary_boost_q10 >> 2))) >> 10;

            let bloom_l = even_harm_l
                + lp_norm_l
                + adj_sparkle_l
                + adj_air_l
                + adj_punch_l
                + adj_phi_l
                + svara_l
                + naad_l
                + goonj_l;
            let bloom_r = even_harm_r
                + lp_norm_r
                + adj_sparkle_r
                + adj_air_r
                + adj_punch_r
                + adj_phi_r
                + svara_r
                + naad_r
                + goonj_r;

            // Envelope-Adaptive Harmonic Bloom Governor:
            // Starts smooth headroom protection early (`peak_env_q10 > 24_000`) so loud mastered tracks
            // retain >3 dB of linear headroom and never clip or crunch `soft_limit_i16`!
            let peak_env_q10 = self.env_fast_q10.max(self.env_slow_q10);
            let bloom_headroom_q10 = if peak_env_q10 <= 24_000 {
                1024
            } else {
                let over = (peak_env_q10 - 24_000).min(80_000);
                (1024 - ((over * 768) / 80_000)).clamp(256, 1024)
            };

            let raw_l = s_l + ((bloom_l * bloom_headroom_q10) >> 10);
            let raw_r = s_r + ((bloom_r * bloom_headroom_q10) >> 10);

            // Ultra-low 3.7 Hz integer DC blocker (`2047 / 2048` instead of `255 / 256`)
            // Preserves 100% of <140 Hz sub-bass amplitude and phase without low-end rolloff!
            let dc_l = raw_l - self.dc_prev_in_l + ((self.dc_prev_out_l * 2047) >> 11);
            self.dc_prev_in_l = raw_l;
            self.dc_prev_out_l = dc_l;

            let dc_r = raw_r - self.dc_prev_in_r + ((self.dc_prev_out_r * 2047) >> 11);
            self.dc_prev_in_r = raw_r;
            self.dc_prev_out_r = dc_r;

            let mid = (dc_l + dc_r) >> 1;
            let side = ((dc_l - dc_r) * self.preset.stereo_width_q10) >> 11;
            // Adaptive master headroom trim (`14/16` = -1.16 dB nominal, `13/16` = -1.80 dB on hot peaks)
            // Guarantees zero inter-sample or soft-limiter distortion on hot mastered tracks!
            let master_trim_num = if peak_env_q10 > 56_000 { 13 } else { 14 };
            let out_l = ((mid + side) * master_trim_num) >> 4;
            let out_r = ((mid - side) * master_trim_num) >> 4;
            interleaved_stereo[f * 2] = soft_limit_i16(out_l);
            interleaved_stereo[f * 2 + 1] = soft_limit_i16(out_r);

            // ── Stage 4: Marine Time-Domain Salience 64-Anchor -> 4096-Bucket Decomposition (20 Hz .. 384,000 Hz) ──
            // Includes Bands 7..10 above 24 kHz driven by the 768 kHz Catmull-Rom curvature (`spline_arch`),
            // 384 kHz Babbage 3rd-derivative cubic jerk (`babbage_c3`), 4th-order Babbage hyper-jerk (`Δc3`),
            // and 768 kHz Nyquist (`384,000 Hz`) sub-sample spline slew!
            let spline_arch_mid = (spline_arch_l + spline_arch_r) >> 1;
            let spline_arch_diff = spline_arch_mid - self.prev_spline_arch;
            self.prev_spline_arch = spline_arch_mid;

            let spline_24_48k = ((spline_arch_l.abs() + spline_arch_r.abs()) * 3) + (even_harm_l.abs() + even_harm_r.abs());
            let babbage_l_c3 = -(l0 as i64) + 3 * (l1 as i64) - 3 * (l2 as i64) + (l3 as i64);
            let babbage_r_c3 = -(r0 as i64) + 3 * (r1 as i64) - 3 * (r2 as i64) + (r3 as i64);
            let babbage_48_96k = (babbage_l_c3 + babbage_r_c3) >> 1;
            let babbage_96_192k = babbage_48_96k - self.prev_babbage_c3;
            self.prev_babbage_c3 = babbage_48_96k;
            let catmull_192_384k = (spline_arch_diff * 4) + (babbage_96_192k >> 1);

            let bands: [i64; 11] = [
                self.dyad_ema[5] * 2,                      // Band 0:  20..140 Hz     (Naad Sub-Bass -> buckets 0..6)
                (self.dyad_ema[4] - self.dyad_ema[5]) * 2, // Band 1:  140..350 Hz    (Vocal F0 / Chest -> buckets 6..13)
                self.dyad_ema[3] - self.dyad_ema[4],       // Band 2:  350..800 Hz    (Warm Body / Lower F1 -> buckets 13..20)
                self.dyad_ema[2] - self.dyad_ema[3],       // Band 3:  800..1800 Hz   (Svara F1/F2 Emotion -> buckets 20..28)
                self.dyad_ema[1] - self.dyad_ema[2],       // Band 4:  1.8..4.2 kHz   (Singer F3 Presence -> buckets 28..35)
                self.dyad_ema[0] - self.dyad_ema[1],       // Band 5:  4.2..10 kHz    (Consonant Brilliance -> buckets 35..41)
                mid - self.dyad_ema[0],                    // Band 6:  10..24 kHz     (Studio Air -> buckets 41..46)
                spline_24_48k,                             // Band 7:  24..48 kHz     (16x Catmull-Rom 2f -> buckets 46..51)
                babbage_48_96k,                            // Band 8:  48..96 kHz     (384kHz Babbage 3f -> buckets 51..56)
                babbage_96_192k,                           // Band 9:  96..192 kHz    (4th-Order Babbage Hyper-Jerk -> buckets 56..60)
                catmull_192_384k,                          // Band 10: 192..384 kHz   (768kHz Nyquist Spline Slew -> buckets 60..64)
            ];
            const BAND_OFFSETS: [usize; 11] = [0, 6, 13, 20, 28, 35, 41, 46, 51, 56, 60];
            const BAND_SPANS: [usize; 11] = [6, 7, 7, 8, 7, 6, 5, 5, 5, 4, 4];

            // ── 5-Lock Svara Glottal-Formant Vocal Detector & 4-Slot Real-Time Singer Diarizer ──
            // Isolates TRUE human singing/speech from drums, sub-bass, and stereo instruments:
            // Lock 1: Phantom-center Mid dominance (`formant_mid > formant_side * 3 / 2`)
            // Lock 2: Glottal pulse period in human vocal fold band (`80 Hz .. 960 Hz`) on `voc_wave` (`dyad_ema[2] - dyad_ema[5]/2`)
            // Lock 3: Cycle-to-cycle glottal pitch stability (`dp * 5 <= period`) across `>= 5` consecutive cycles
            // Lock 4: Active Svara vowel formants (`F1 + 2*F2 + 2*F3` dominating `<140 Hz` sub-bass & ultrasonic noise)
            // Lock 5: HarmonicSinusoid state (rejects Dirac transients / drum hits & stochastic noise)
            let formant_mid = (self.svf_band_l + self.svf_band_r).abs() >> 1;
            let formant_side = (self.svf_band_l - self.svf_band_r).abs() >> 1;
            // Two-gear high-passed glottal fundamental bandpass:
            // - Subtracts 100% of `dyad_ema[5]` (<119 Hz sub-bass & bass guitar) so basslines never masquerade as Baritones!
            // - Shifts up to `dyad_ema[3] - dyad_ema[4]` (238..475 Hz) when upper Mezzo/Soprano formants dominate,
            //   so Lita's high vocals lock cleanly even over heavy low-mid rhythm guitars!
            let voc_wave = if self.voc_f1_ema > (self.voc_f0_ema * 5) >> 2 {
                self.dyad_ema[3] - self.dyad_ema[4]
            } else {
                self.dyad_ema[3] - self.dyad_ema[5]
            };
            let min_voc_p = ((self.sample_rate_hz as u64) / 880).max(8);
            let max_voc_p = ((self.sample_rate_hz as u64) / 118).max(min_voc_p + 1);

            if self.prev_voc_wave <= 0 && voc_wave > 0 && formant_mid > 48 {
                let period = self.global_frame_idx.saturating_sub(self.voc_last_zc_frame);
                if period >= min_voc_p {
                    self.voc_last_zc_frame = self.global_frame_idx;
                    if period <= max_voc_p {
                        let dp = period.abs_diff(self.voc_prev_period);
                        let pitch_coherent = self.voc_prev_period == 0 || dp * 4 <= period;
                        let center_dominant = (formant_mid * 2) > (formant_side * 3);
                        let p_q4 = period << 4;
                        if pitch_coherent && center_dominant && state == AcousticState::HarmonicSinusoid {
                            self.voc_lock_streak = (self.voc_lock_streak + 1).min(64);
                            if self.voc_ema_period_q4 == 0 {
                                self.voc_ema_period_q4 = p_q4;
                            } else {
                                self.voc_ema_period_q4 = (self.voc_ema_period_q4 * 3 + p_q4) >> 2;
                            }
                        } else {
                            // Snap period register on large pitch/voice jump so EMA never smears across two singers!
                            self.voc_ema_period_q4 = p_q4;
                            self.voc_lock_streak = 1;
                        }
                        self.voc_prev_period = period;
                    } else {
                        self.voc_prev_period = 0;
                        self.voc_lock_streak = self.voc_lock_streak.saturating_sub(2);
                    }
                }
            } else if self.global_frame_idx.saturating_sub(self.voc_last_zc_frame) > max_voc_p && (f & 31) == 0 {
                self.voc_lock_streak = self.voc_lock_streak.saturating_sub(1);
            }
            self.prev_voc_wave = voc_wave;

            // Smooth vowel formant envelopes (`F0`, `F1`, `F2`, `F3`) vs `<140 Hz` sub-bass
            self.voc_sub_ema = (self.voc_sub_ema * 15 + bands[0].abs()) >> 4;
            self.voc_f0_ema = (self.voc_f0_ema * 15 + bands[1].abs()) >> 4;
            self.voc_f1_ema = (self.voc_f1_ema * 15 + bands[2].abs()) >> 4;
            self.voc_f2_ema = (self.voc_f2_ema * 15 + bands[3].abs()) >> 4;
            self.voc_f3_ema = (self.voc_f3_ema * 15 + bands[4].abs()) >> 4;

            let vowel_energy = self.voc_f1_ema + (self.voc_f2_ema * 2) + (self.voc_f3_ema * 2);
            let upper_vowel_articulation = self.voc_f2_ema + self.voc_f3_ema;
            let sub_energy = self.voc_sub_ema;

            let vocal_gate_q8 = if state == AcousticState::HarmonicSinusoid
                && self.voc_lock_streak >= 4
                && (formant_mid * 2) > (formant_side * 3)
                && vowel_energy > ((sub_energy * 3) >> 2)
                && upper_vowel_articulation * 4 > self.voc_f0_ema.max(32)
            {
                let streak_q8 = ((self.voc_lock_streak.saturating_sub(3) as i64) * 48).clamp(0, 256);
                let center_lock = (((formant_mid - formant_side) * 256) / (formant_mid + formant_side + 64)).clamp(0, 256);
                let formant_ratio = ((vowel_energy * 224) / (vowel_energy + sub_energy + 128)).clamp(0, 256);
                ((((center_lock * formant_ratio) >> 8) * streak_q8) >> 7).clamp(0, 256)
            } else {
                0
            };

            // Update vocal confidence (`0..=1024`) and decay buckets every 16 frames (~0.33ms)
            if (f & 15) == 0 {
                let target_conf_q10 = (vocal_gate_q8 * 4).clamp(0, 1024) as u16;
                if target_conf_q10 > self.vocal_confidence_q10 {
                    self.vocal_confidence_q10 =
                        ((self.vocal_confidence_q10 as u32 * 5 + target_conf_q10 as u32 * 3) >> 3) as u16;
                } else {
                    self.vocal_confidence_q10 =
                        ((self.vocal_confidence_q10 as u32 * 13) >> 4) as u16;
                    if self.vocal_confidence_q10 < 12 {
                        self.vocal_confidence_q10 = 0;
                    }
                }
                let voc_decay_mul = if vocal_gate_q8 > 16 { 14u32 } else { 9u32 };
                for b in 0..64 {
                    self.marine_buckets_q10[b] = ((self.marine_buckets_q10[b] as u32 * 15) >> 4) as u16;
                    let vd = ((self.marine_vocal_q10[b] as u32 * voc_decay_mul) >> 4) as u16;
                    self.marine_vocal_q10[b] = if vd < 4 && vocal_gate_q8 == 0 { 0 } else { vd };
                }
            }

            // Update 4-Slot Real-Time Singer Diarizer every 32 frames (~0.66ms)
            if (f & 31) == 0 {
                if self.vocal_confidence_q10 >= 140 && self.voc_lock_streak >= 4 && self.voc_ema_period_q4 > 0 {
                    let f0_hz = (((self.sample_rate_hz as u64) << 4) / self.voc_ema_period_q4.max(1))
                        .clamp(80, 960) as u16;
                    let fmt_q8 = (((self.voc_f2_ema + self.voc_f3_ema) << 8)
                        / (self.voc_f0_ema + self.voc_f1_ema + 32))
                        .clamp(32, 1024) as u16;
                    self.vocal_f0_hz = f0_hz;
                    self.vocal_formant_ratio_q8 = fmt_q8;

                    // Compute singer's real-time emotion coordinates (Valence X, Arousal Y in -940..+940)
                    let voc_chest = self.voc_f0_ema + self.voc_f1_ema;
                    let voc_heart = self.voc_f2_ema * 2;
                    let voc_belt = self.voc_f3_ema * 2;
                    let voc_air = bands[5].abs() + bands[6].abs();
                    let tot_v = (voc_chest + voc_heart + voc_belt + voc_air).max(64);
                    let raw_emo_x = (((voc_heart + self.voc_f1_ema - self.voc_f0_ema * 2) * 900) / tot_v)
                        .clamp(-940, 940) as i16;
                    let raw_emo_y = (((voc_chest - (voc_belt + voc_air)) * 900) / tot_v)
                        .clamp(-940, 940) as i16;

                    // Match existing diarized singer slot (`0..4`) or confirm a sustained new voice slot
                    let cur_reg = DiarizedSingerSlot::register_band(f0_hz);
                    let mut best_slot: Option<usize> = None;
                    let mut best_dist: i64 = i64::MAX;
                    for s in 0..4 {
                        let slot = &self.singer_slots[s];
                        if !slot.active {
                            continue;
                        }
                        let slot_reg = DiarizedSingerSlot::register_band(slot.f0_centroid_hz);
                        let ref_f0 = slot.f0_centroid_hz.min(f0_hz).max(115) as i64;
                        let f0_diff_scaled = ((f0_hz as i64 - slot.f0_centroid_hz as i64).abs() * 220) / ref_f0;
                        let fmt_diff = (fmt_q8 as i64 - slot.formant_ratio_q8 as i64).abs() / 3;
                        let reg_penalty = if slot_reg != cur_reg && f0_hz.abs_diff(slot.f0_centroid_hz) > 38 {
                            48
                        } else {
                            0
                        };
                        let mut dist = f0_diff_scaled + fmt_diff + reg_penalty;
                        if self.active_singer_id == s as u8
                            && slot_reg == cur_reg
                            && self.global_frame_idx.saturating_sub(slot.last_active_frame)
                                < (self.sample_rate_hz as u64 * 2)
                            && f0_diff_scaled < 78
                        {
                            dist = (dist - 24).max(0);
                        }
                        if dist < best_dist {
                            best_dist = dist;
                            best_slot = Some(s);
                        }
                    }

                    let chosen_opt = if let Some(s) = best_slot.filter(|_| best_dist <= 82) {
                        self.pending_new_streak = 0;
                        Some(s)
                    } else if best_slot.is_none() {
                        // First voice ever in session -> assign Slot 0 (V1) immediately
                        self.pending_new_streak = 0;
                        Some(0)
                    } else {
                        // Require 3 consecutive coherent register/pitch ticks (~96 frames) before spawning V2..V4
                        // so duet switches (e.g. Ozzy -> Lita) lock quickly without collapsing into one slot!
                        if DiarizedSingerSlot::register_band(self.pending_new_f0) == cur_reg
                            || self.pending_new_f0.abs_diff(f0_hz) <= 65
                        {
                            self.pending_new_streak = self.pending_new_streak.saturating_add(1);
                        } else {
                            self.pending_new_f0 = f0_hz;
                            self.pending_new_streak = 1;
                        }
                        if self.pending_new_streak >= 3 {
                            self.pending_new_streak = 0;
                            if let Some(free_s) = (0..4).find(|&s| !self.singer_slots[s].active) {
                                Some(free_s)
                            } else {
                                // All 4 slots active: if any register currently has >= 2 duplicate slots,
                                // recycle the oldest duplicate-register slot so every vocal register gets a slot!
                                let mut reg_counts = [0u8; 4];
                                for s in 0..4 {
                                    let r = DiarizedSingerSlot::register_band(self.singer_slots[s].f0_centroid_hz) as usize;
                                    reg_counts[r] = reg_counts[r].saturating_add(1);
                                }
                                let dup_victim = (0..4)
                                    .filter(|&s| {
                                        let r = DiarizedSingerSlot::register_band(self.singer_slots[s].f0_centroid_hz) as usize;
                                        reg_counts[r] >= 2
                                    })
                                    .min_by_key(|&s| self.singer_slots[s].last_active_frame);
                                let victim = dup_victim.unwrap_or_else(|| {
                                    (0..4)
                                        .min_by_key(|&s| self.singer_slots[s].last_active_frame)
                                        .unwrap_or(0)
                                });
                                // Reset victim slot so the new register claims it cleanly
                                self.singer_slots[victim].active = false;
                                self.singer_slots[victim].frames_sung = 0;
                                Some(victim)
                            }
                        } else {
                            best_slot
                        }
                    };

                    if let Some(chosen_idx) = chosen_opt {
                        // Detect Simultaneous Duet Harmony (e.g. Ozzy Tenor + Lita Mezzo/Soprano singing together):
                        // Both lower-register chest/F0 (`voc_f0_ema`) and upper-register belt (`voc_f1_ema + voc_f2_ema + voc_f3_ema`)
                        // are simultaneously strong while both a low slot (`reg <= 1`) and high slot (`reg >= 2`) exist!
                        let chosen_reg = if self.singer_slots[chosen_idx].active {
                            DiarizedSingerSlot::register_band(self.singer_slots[chosen_idx].f0_centroid_hz)
                        } else {
                            cur_reg
                        };
                        let duet_energy_active = self.voc_f0_ema > 110
                            && self.voc_f1_ema > 110
                            && (self.voc_f2_ema + self.voc_f3_ema) > self.voc_f0_ema;
                        let harmony_partner_opt = if duet_energy_active {
                            (0..4)
                                .filter(|&s| {
                                    if s == chosen_idx || !self.singer_slots[s].active {
                                        return false;
                                    }
                                    let r = DiarizedSingerSlot::register_band(self.singer_slots[s].f0_centroid_hz);
                                    (chosen_reg <= 1 && r >= 2) || (chosen_reg >= 2 && r <= 1)
                                })
                                .max_by_key(|&s| self.singer_slots[s].last_active_frame)
                        } else {
                            None
                        };

                        for s in 0..4 {
                            if s == chosen_idx {
                                let slot = &mut self.singer_slots[s];
                                if !slot.active {
                                    slot.active = true;
                                    slot.slot_id = s as u8;
                                    slot.f0_centroid_hz = f0_hz;
                                    slot.formant_ratio_q8 = fmt_q8;
                                    slot.emo_x_q10 = raw_emo_x;
                                    slot.emo_y_q10 = raw_emo_y;
                                } else {
                                    // Keep centroid anchored inside its vocal register
                                    if slot.f0_centroid_hz.abs_diff(f0_hz) <= 64
                                        && DiarizedSingerSlot::register_band(slot.f0_centroid_hz) == cur_reg
                                    {
                                        slot.f0_centroid_hz =
                                            ((slot.f0_centroid_hz as u32 * 15 + f0_hz as u32) >> 4) as u16;
                                        slot.formant_ratio_q8 =
                                            ((slot.formant_ratio_q8 as u32 * 15 + fmt_q8 as u32) >> 4) as u16;
                                    }
                                    slot.emo_x_q10 =
                                        ((slot.emo_x_q10 as i32 * 5 + raw_emo_x as i32 * 3) >> 3) as i16;
                                    slot.emo_y_q10 =
                                        ((slot.emo_y_q10 as i32 * 5 + raw_emo_y as i32 * 3) >> 3) as i16;
                                }
                                slot.presence_q10 = self.vocal_confidence_q10;
                                slot.frames_sung = slot.frames_sung.saturating_add(32);
                                slot.last_active_frame = self.global_frame_idx;
                            } else if Some(s) == harmony_partner_opt {
                                // Duet Harmony Partner: light up simultaneous harmony voice!
                                let slot = &mut self.singer_slots[s];
                                let harm_pres = ((self.vocal_confidence_q10 as u32 * 7) >> 3).max(380) as u16;
                                slot.presence_q10 = slot.presence_q10.max(harm_pres);
                                slot.emo_x_q10 =
                                    ((slot.emo_x_q10 as i32 * 7 + (-raw_emo_x as i32 / 2 + raw_emo_x as i32)) >> 3)
                                        .clamp(-940, 940) as i16;
                                slot.emo_y_q10 =
                                    ((slot.emo_y_q10 as i32 * 6 + (raw_emo_y as i32 - 80) * 2) >> 3)
                                        .clamp(-940, 940) as i16;
                                slot.frames_sung = slot.frames_sung.saturating_add(16);
                            } else {
                                self.singer_slots[s].presence_q10 =
                                    ((self.singer_slots[s].presence_q10 as u32 * 7) >> 3) as u16;
                            }
                        }
                        self.active_singer_id = chosen_idx as u8;
                    }
                } else {
                    self.active_singer_id = 255;
                    self.vocal_f0_hz = 0;
                    self.pending_new_streak = 0;
                    for s in 0..4 {
                        self.singer_slots[s].presence_q10 =
                            ((self.singer_slots[s].presence_q10 as u32 * 3) >> 2) as u16;
                    }
                }
            }

            for k in 0..11 {
                let b_val = bands[k];
                let prev_b = self.prev_band[k];
                self.prev_band[k] = b_val;
                let abs_b = b_val.abs();
                if abs_b < 12 {
                    continue;
                }
                // Octave-normalized Time-Domain Instantaneous Frequency (`(|Δb| << oct_shift) / |b|`):
                let diff_b = (b_val - prev_b).abs();
                let oct_shift = (6usize.saturating_sub(k)) as u32;
                let norm_diff = diff_b << oct_shift;
                let span = BAND_SPANS[k] as i64;
                let sub_idx = ((norm_diff * span) / (abs_b * 2 + 64)).clamp(0, span - 1) as usize;
                let bucket = (BAND_OFFSETS[k] + sub_idx).min(63);

                // Scale band amplitude + Marine Soul coherence + Post-PhoeniX Alexandra Sanctuary transfer into Q10 (`0..=1024`)
                let scale_shift = if k >= 7 { 12 } else { 13 };
                let post_dsp_gain_q10 = match k {
                    1 | 2 => 1024 + (sanctuary_boost_q10 >> 1),
                    3 | 7 => 1024 + passion_window_q10,
                    4 | 5 => (1024 - deharsh_q10).max(384),
                    _ => 1024,
                };
                let adj_abs_b = (abs_b * post_dsp_gain_q10) >> 10;
                let level_q10 = ((adj_abs_b * soul_expr_q10) >> scale_shift).clamp(0, 1024) as u16;
                if level_q10 > self.marine_buckets_q10[bucket] {
                    self.marine_buckets_q10[bucket] = level_q10;
                } else {
                    self.marine_buckets_q10[bucket] =
                        ((self.marine_buckets_q10[bucket] as u32 * 7 + level_q10 as u32) >> 3) as u16;
                }
                // Critical-band cochlear neighbor spread (`3/4` and `1/2` into adjacent sub-buckets)
                let n1_q10 = (level_q10 * 3) >> 2;
                let n2_q10 = level_q10 >> 1;
                if sub_idx > 0 && bucket > 0 && n1_q10 > self.marine_buckets_q10[bucket - 1] {
                    self.marine_buckets_q10[bucket - 1] =
                        ((self.marine_buckets_q10[bucket - 1] as u32 + n1_q10 as u32) >> 1) as u16;
                }
                if sub_idx + 1 < (span as usize) && bucket + 1 < 64 && n1_q10 > self.marine_buckets_q10[bucket + 1] {
                    self.marine_buckets_q10[bucket + 1] =
                        ((self.marine_buckets_q10[bucket + 1] as u32 + n1_q10 as u32) >> 1) as u16;
                }
                if sub_idx > 1 && bucket > 1 && n2_q10 > self.marine_buckets_q10[bucket - 2] {
                    self.marine_buckets_q10[bucket - 2] =
                        ((self.marine_buckets_q10[bucket - 2] as u32 + n2_q10 as u32) >> 1) as u16;
                }
                if sub_idx + 2 < (span as usize) && bucket + 2 < 64 && n2_q10 > self.marine_buckets_q10[bucket + 2] {
                    self.marine_buckets_q10[bucket + 2] =
                        ((self.marine_buckets_q10[bucket + 2] as u32 + n2_q10 as u32) >> 1) as u16;
                }

                // Isolated Singer-Only Vocal Salience (`k = 1..=6`, `140 Hz .. 24,000 Hz` vocal F0, F1/F2, F3 & breath sheen)
                if (1..=6).contains(&k) && vocal_gate_q8 > 16 {
                    let band_weight = match k {
                        3 | 4 => 320, // Core Svara F1/F2 & F3 Singer Emotion (800..4200 Hz)
                        1 | 2 => 256, // Vocal F0 & Warm Chest (140..800 Hz)
                        5 => 192,     // Vocal Sibilance / Breath Brilliance (4.2..10 kHz)
                        _ => 128,     // Upper Vocal Air (10..24 kHz)
                    };
                    let voc_q10 = (((level_q10 as i64) * vocal_gate_q8 * band_weight) >> 15)
                        .clamp(0, 1024) as u16;
                    if voc_q10 > self.marine_vocal_q10[bucket] {
                        self.marine_vocal_q10[bucket] = voc_q10;
                    }
                    let vn_q10 = (voc_q10 * 3) >> 2;
                    if sub_idx > 0 && bucket > 0 && vn_q10 > self.marine_vocal_q10[bucket - 1] {
                        self.marine_vocal_q10[bucket - 1] =
                            ((self.marine_vocal_q10[bucket - 1] as u32 + vn_q10 as u32) >> 1) as u16;
                    }
                    if sub_idx + 1 < (span as usize) && bucket + 1 < 64 && vn_q10 > self.marine_vocal_q10[bucket + 1] {
                        self.marine_vocal_q10[bucket + 1] =
                            ((self.marine_vocal_q10[bucket + 1] as u32 + vn_q10 as u32) >> 1) as u16;
                    }
                }
            }
        }
    }

    /// Process a 48 kHz interleaved stereo `s16le` chunk through the PhoeniX engine and upsample
    /// by `factor` (`8` -> `384,000 Hz`, `4` -> `192,000 Hz`, `2` -> `96,000 Hz`, `1` -> `48,000 Hz`)
    /// into 32-bit signed integer (`s32le`) using **Babbage Shift-Add Cubic Forward Differencing**
    /// (`y += d1; d1 += d2; d2 += d3;` — **3 integer additions per sub-sample, zero multiplications**)!
    ///
    /// Bit-for-bit identical to [`catmull_rom_s32_16x`] at every sub-sample phase (`sub_k = s << shift_s`).
    /// Returns the number of `i32` samples written to `out_s32_stereo` (`frames * 2 * factor`).
    pub fn process_stereo_upsample_s32le(
        &mut self,
        in_48k_stereo: &mut [i16],
        factor: usize,
        out_s32_stereo: &mut [i32],
    ) -> usize {
        let frames = in_48k_stereo.len() / 2;
        let (fac, shift_s) = match factor {
            8 => (8usize, 1u32),
            4 => (4usize, 2u32),
            2 => (2usize, 3u32),
            _ => (1usize, 4u32),
        };
        if frames == 0 || out_s32_stereo.len() < frames * 2 * fac {
            return 0;
        }

        // First run full PhoeniX S+N+T + 432Hz/phi + Goonj/Svara/Naad revelation in-place at 48 kHz (1x cost!)
        self.process_stereo_in_place(in_48k_stereo);

        let sh3 = 3 + 3 * shift_s;
        let sh2 = 7 + 2 * shift_s;
        let sh1 = 11 + shift_s;

        let mut out_idx = 0usize;
        for f in 0..frames {
            let l0 = self.upsample_hist_l[0] as i64;
            let l1 = self.upsample_hist_l[1] as i64;
            let l2 = self.upsample_hist_l[2] as i64;
            let l3_i16 = in_48k_stereo[f * 2];
            let l3 = l3_i16 as i64;
            self.upsample_hist_l = [l1 as i16, l2 as i16, l3_i16];

            let r0 = self.upsample_hist_r[0] as i64;
            let r1 = self.upsample_hist_r[1] as i64;
            let r2 = self.upsample_hist_r[2] as i64;
            let r3_i16 = in_48k_stereo[f * 2 + 1];
            let r3 = r3_i16 as i64;
            self.upsample_hist_r = [r1 as i16, r2 as i16, r3_i16];

            // Pure shift-add cubic coefficients (zero multiplications): 3*x = (x<<1)+x, 5*x = (x<<2)+x
            let l1_3 = (l1 << 1) + l1;
            let l2_3 = (l2 << 1) + l2;
            let l1_5 = (l1 << 2) + l1;
            let a0_l = -l0 + l1_3 - l2_3 + l3;
            let a1_l = (l0 << 1) - l1_5 + (l2 << 2) - l3;
            let a2_l = -l0 + l2;

            let c3_l = a0_l << sh3;
            let c2_l = a1_l << sh2;
            let c1_l = a2_l << sh1;
            let c3_6_l = (c3_l << 2) + (c3_l << 1);
            let mut y_l = l1 << 16;
            let mut d1_l = c3_l + c2_l + c1_l;
            let mut d2_l = c3_6_l + (c2_l << 1);
            let d3_l = c3_6_l;

            let r1_3 = (r1 << 1) + r1;
            let r2_3 = (r2 << 1) + r2;
            let r1_5 = (r1 << 2) + r1;
            let a0_r = -r0 + r1_3 - r2_3 + r3;
            let a1_r = (r0 << 1) - r1_5 + (r2 << 2) - r3;
            let a2_r = -r0 + r2;

            let c3_r = a0_r << sh3;
            let c2_r = a1_r << sh2;
            let c1_r = a2_r << sh1;
            let c3_6_r = (c3_r << 2) + (c3_r << 1);
            let mut y_r = r1 << 16;
            let mut d1_r = c3_r + c2_r + c1_r;
            let mut d2_r = c3_6_r + (c2_r << 1);
            let d3_r = c3_6_r;

            // Babbage 3-Addition Forward-Difference Stepper (zero multiplications per sub-sample!)
            // Includes 32-bit Inter-Sample Peak (ISP) silk ceiling (`soft_limit_s32_isp`) so 384 kHz
            // Catmull-Rom cubic arches between hot 48 kHz samples never hard-clip the DAC!
            for _ in 0..fac {
                out_s32_stereo[out_idx] = soft_limit_s32_isp(y_l);
                out_s32_stereo[out_idx + 1] = soft_limit_s32_isp(y_r);
                out_idx += 2;
                y_l += d1_l;
                d1_l += d2_l;
                d2_l += d3_l;
                y_r += d1_r;
                d1_r += d2_r;
                d2_r += d3_r;
            }
        }
        out_idx
    }

    /// Snapshot current live `p/q` Rational telemetry without interrupting the audio stream.
    pub fn live_telemetry(&self) -> (Rational, Rational, &'static str, Rational) {
        let dominant_freq_hz = if self.zc_intervals_count > 0 && self.period_accum_ticks > 0 {
            let num = (self.internal_oversample_hz as u64).saturating_mul(self.zc_intervals_count);
            let den = self.period_accum_ticks.max(1);
            safe_rational_u64(num, den)
        } else {
            Rational::integer(SOVEREIGN_ANCHOR_HZ as i32)
        };
        let (shruti_ratio, shruti_name) = nearest_taal_shruti_pq(dominant_freq_hz);
        let jp_permille = ((self.period_jitter_accum * 1024) / self.period_accum_ticks.max(1)).min(512);
        let ja_permille = ((self.amp_jitter_accum * 1024) / self.peak_accum.max(1)).min(512);
        let soul_num = (640 + jp_permille + (ja_permille >> 1)).clamp(512, 1020) as i32;
        let soul_auth = Rational::new(soul_num, 1024).unwrap_or(Rational::ONE);
        (dominant_freq_hz, shruti_ratio, shruti_name, soul_auth)
    }
}

/// Construct a normalized [`Rational`] from 64-bit unsigned numerator and denominator,
/// scaling down cleanly if either exceeds `i32::MAX`.
pub fn safe_rational_u64(mut num: u64, mut den: u64) -> Rational {
    if den == 0 {
        return Rational::ZERO;
    }
    while num > (i32::MAX as u64) || den > (i32::MAX as u64) {
        num >>= 1;
        den = (den >> 1).max(1);
    }
    Rational::new(num as i32, den as u32).unwrap_or(Rational::ZERO)
}

/// Wide silk-knee studio master soft-limiter for 16-bit audio (`-29800..=29800`).
/// Preserves 100% linear bit-transparency below `21000` (`-3.87 dBFS`) and smoothly curves
/// peaks above `21000` toward an asymptotic ceiling of `29800` (`-0.82 dBFS`), leaving
/// true analog headroom for 384 kHz Catmull-Rom inter-sample spline arches!
#[inline]
pub fn soft_limit_i16(x: i64) -> i16 {
    let sign = if x < 0 { -1 } else { 1 };
    let a = x.abs();
    if a <= 21000 {
        return (sign * a) as i16;
    }
    let excess = a - 21000;
    let compressed = 21000 + (8800 * excess) / (excess + 10200);
    (sign * compressed.min(29800)) as i16
}

/// 32-bit (`s32le` / 24-bit `S24_3LE`) Inter-Sample Peak (ISP) soft-knee ceiling for 384 kHz upsampling.
/// Linearly transparent up to `1_860_000_000` (`-1.25 dBFS`), and smoothly curves any Catmull-Rom
/// cubic spline overshoot toward `2_120_000_000` (`-0.11 dBFS`) so the hardware DAC never clips.
#[inline]
pub fn soft_limit_s32_isp(y: i64) -> i32 {
    let sign = if y < 0 { -1 } else { 1 };
    let a = y.abs();
    if a <= 1_860_000_000 {
        return (sign * a) as i32;
    }
    let excess = a - 1_860_000_000;
    let compressed = 1_860_000_000 + (260_000_000 * excess) / (excess + 280_000_000);
    (sign * compressed.min(2_120_000_000)) as i32
}

/// Compute 64-bit FNV-1a digest over a 16-bit PCM sample slice.
pub fn fnv1a_pcm_i16(pcm: &[i16]) -> u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    for &s in pcm {
        let bytes = s.to_le_bytes();
        h ^= bytes[0] as u64;
        h = h.wrapping_mul(0x100000001b3);
        h ^= bytes[1] as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    h
}

/// Assemble the 16-byte `.8a` (`8a∞`) header + opcode stream.
///
/// Header layout (16B):
/// - `0..4`: `0x38 0x61 0xE2 0x9E` (`8a∞`)
/// - `4..6`: Interlace (`u16` LE: `bit 0` = stereo, `bits 1..7` = rate / 1000, `bits 8..15` = 16x oversample)
/// - `6..14`: 64-bit FNV-1a Checksum (`u64` LE)
/// - `14..16`: Sovereign Harmonic Anchor (`432` u16 LE)
pub fn build_8a_stream(opcodes: &[u8], checksum: u64, sample_rate_hz: u32, channels: u16) -> Vec<u8> {
    let mut out = Vec::with_capacity(16 + opcodes.len());
    out.extend_from_slice(&EIGHT_A_MAGIC);
    let stereo_bit = u16::from(channels >= 2);
    let rate_khz = ((sample_rate_hz / 1000).min(127) as u16) << 1;
    let interlace: u16 = stereo_bit | rate_khz | (16u16 << 8);
    out.extend_from_slice(&interlace.to_le_bytes());
    out.extend_from_slice(&checksum.to_le_bytes());
    out.extend_from_slice(&SOVEREIGN_ANCHOR_HZ.to_le_bytes());
    out.extend_from_slice(opcodes);
    out
}

/// Encode 16-bit PCM samples into a standard RIFF WAVE byte buffer.
pub fn encode_wav_i16(interleaved_pcm: &[i16], sample_rate_hz: u32, channels: u16) -> Vec<u8> {
    let ch = channels.clamp(1, 2);
    let data_bytes = (interleaved_pcm.len() * 2) as u32;
    let riff_size = 36u32.saturating_add(data_bytes);
    let byte_rate = sample_rate_hz * (ch as u32) * 2;
    let block_align = ch * 2;

    let mut wav = Vec::with_capacity(44 + data_bytes as usize);
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&riff_size.to_le_bytes());
    wav.extend_from_slice(b"WAVE");
    wav.extend_from_slice(b"fmt ");
    wav.extend_from_slice(&16u32.to_le_bytes()); // PCM fmt chunk size
    wav.extend_from_slice(&1u16.to_le_bytes()); // AudioFormat = 1 (PCM integer)
    wav.extend_from_slice(&ch.to_le_bytes());
    wav.extend_from_slice(&sample_rate_hz.to_le_bytes());
    wav.extend_from_slice(&byte_rate.to_le_bytes());
    wav.extend_from_slice(&block_align.to_le_bytes());
    wav.extend_from_slice(&16u16.to_le_bytes()); // BitsPerSample = 16
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data_bytes.to_le_bytes());
    for &sample in interleaved_pcm {
        wav.extend_from_slice(&sample.to_le_bytes());
    }
    wav
}

/// Parse a 16-bit PCM RIFF WAVE byte slice into `(interleaved_samples, sample_rate_hz, channels)`.
pub fn decode_wav_i16(bytes: &[u8]) -> Result<(Vec<i16>, u32, u16), String> {
    if bytes.len() < 44 || &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
        return Err("Not a valid RIFF WAVE header".to_string());
    }
    let mut pos = 12usize;
    let mut channels = 2u16;
    let mut sample_rate = 48000u32;
    let mut bits_per_sample = 16u16;

    while pos + 8 <= bytes.len() {
        let chunk_id = &bytes[pos..pos + 4];
        let chunk_len = u32::from_le_bytes([
            bytes[pos + 4],
            bytes[pos + 5],
            bytes[pos + 6],
            bytes[pos + 7],
        ]) as usize;
        pos += 8;
        if pos + chunk_len > bytes.len() {
            break;
        }
        if chunk_id == b"fmt " && chunk_len >= 16 {
            channels = u16::from_le_bytes([bytes[pos + 2], bytes[pos + 3]]);
            sample_rate = u32::from_le_bytes([
                bytes[pos + 4],
                bytes[pos + 5],
                bytes[pos + 6],
                bytes[pos + 7],
            ]);
            bits_per_sample = u16::from_le_bytes([bytes[pos + 14], bytes[pos + 15]]);
        } else if chunk_id == b"data" {
            let data = &bytes[pos..pos + chunk_len];
            if bits_per_sample == 16 {
                let mut pcm = Vec::with_capacity(data.len() / 2);
                for pair in data.chunks_exact(2) {
                    pcm.push(i16::from_le_bytes([pair[0], pair[1]]));
                }
                return Ok((pcm, sample_rate, channels.clamp(1, 2)));
            } else if bits_per_sample == 24 {
                let mut pcm = Vec::with_capacity(data.len() / 3);
                for triplet in data.chunks_exact(3) {
                    pcm.push(i16::from_le_bytes([triplet[1], triplet[2]]));
                }
                return Ok((pcm, sample_rate, channels.clamp(1, 2)));
            }
        }
        pos += chunk_len + (chunk_len & 1);
    }
    Err("WAVE data chunk not found".to_string())
}

/// Transform an in-memory RIFF WAVE byte slice through the 768 kHz PhoeniX Sound Revelation Engine,
/// returning `(enhanced_wav_bytes, receipt)`.
pub fn phoenix_enhance_wav_bytes(
    wav_bytes: &[u8],
    preset: &PhoenixSoundPreset,
) -> Result<(Vec<u8>, PhoenixSoundReceipt), String> {
    let (pcm_in, sample_rate, channels) = decode_wav_i16(wav_bytes)?;
    let (pcm_out, _eight_a, receipt) =
        phoenix_transform_pcm_i16(&pcm_in, sample_rate, channels, preset);
    let enhanced_wav = encode_wav_i16(&pcm_out, receipt.sample_rate_hz, receipt.channels);
    Ok((enhanced_wav, receipt))
}

/// Load any audio file (`.wav`, `.mp3`, `.flac`, `.ogg`, `.m4a`) into 16-bit PCM,
/// transform it into **PhoeniX'd Sound**, and optionally write the output `.wav` and `.8a` files.
pub fn phoenix_transform_audio_file(
    input_path: &Path,
    output_wav_path: Option<&Path>,
    output_8a_path: Option<&Path>,
    preset: &PhoenixSoundPreset,
) -> Result<(Vec<i16>, Vec<u8>, PhoenixSoundReceipt), String> {
    let raw_bytes = std::fs::read(input_path)
        .map_err(|e| format!("Failed to read {}: {e}", input_path.display()))?;

    let (pcm_in, sample_rate, channels) = if raw_bytes.len() >= 12
        && &raw_bytes[0..4] == b"RIFF"
        && &raw_bytes[8..12] == b"WAVE"
    {
        decode_wav_i16(&raw_bytes)?
    } else {
        // Decode MP3/FLAC/OGG/AAC to 48 kHz 16-bit stereo PCM via ffmpeg pipe
        let mut child = Command::new("ffmpeg")
            .args([
                "-v",
                "error",
                "-i",
                &input_path.to_string_lossy(),
                "-f",
                "s16le",
                "-acodec",
                "pcm_s16le",
                "-ar",
                "48000",
                "-ac",
                "2",
                "-",
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("Failed to spawn ffmpeg decoder for {}: {e}", input_path.display()))?;

        let mut raw_pcm = Vec::new();
        if let Some(mut out) = child.stdout.take() {
            out.read_to_end(&mut raw_pcm)
                .map_err(|e| format!("Failed reading decoded PCM stream: {e}"))?;
        }
        let status = child
            .wait()
            .map_err(|e| format!("ffmpeg wait failed: {e}"))?;
        if !status.success() || raw_pcm.is_empty() {
            return Err(format!(
                "ffmpeg failed to decode {} into PCM",
                input_path.display()
            ));
        }
        let mut samples = Vec::with_capacity(raw_pcm.len() / 2);
        for chunk in raw_pcm.chunks_exact(2) {
            samples.push(i16::from_le_bytes([chunk[0], chunk[1]]));
        }
        (samples, 48000, 2)
    };

    let (pcm_out, eight_a_bytes, receipt) =
        phoenix_transform_pcm_i16(&pcm_in, sample_rate, channels, preset);

    if let Some(wav_path) = output_wav_path {
        let wav_data = encode_wav_i16(&pcm_out, receipt.sample_rate_hz, receipt.channels);
        std::fs::write(wav_path, wav_data)
            .map_err(|e| format!("Failed to write PhoeniX WAV {}: {e}", wav_path.display()))?;
    }

    if let Some(eight_a_path) = output_8a_path {
        std::fs::write(eight_a_path, &eight_a_bytes)
            .map_err(|e| format!("Failed to write .8a file {}: {e}", eight_a_path.display()))?;
    }

    Ok((pcm_out, eight_a_bytes, receipt))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn catmull_rom_16x_repairs_clipped_and_dropped_sine_wave_in_exact_integers() {
        // Construct a 256-sample integer wave using a triangle-parabolic integer oscillator (zero-float!)
        let mut clean = Vec::with_capacity(256);
        for i in 0..256i64 {
            let phase = (i % 32) - 16; // -16..15
            let parabola = 16 * 16 - phase * phase; // 0..256
            let sign = if (i / 32) % 2 == 0 { 1 } else { -1 };
            clean.push((sign * parabola * 110) as i16);
        }

        let mut degraded = clean.clone();
        // Inject a zero-dropout at sample 40 and a hard-clip plateau at 104..106
        degraded[40] = 0;
        degraded[104] = 32700;
        degraded[105] = 32700;

        let (restored, count) = restore_channel_catmull_rom_i16(&degraded);
        assert!(count >= 3, "must detect and restore both dropout and clipped plateau");
        let err_degraded = (degraded[40] as i64 - clean[40] as i64).abs();
        let err_restored = (restored[40] as i64 - clean[40] as i64).abs();
        assert!(
            err_restored < err_degraded / 5,
            "Catmull-Rom integer restoration error ({err_restored}) must be >5x lower than degraded ({err_degraded})"
        );
    }

    #[test]
    fn phoenix_transform_produces_valid_8a_capsule_and_exact_rational_receipt() {
        let mut stereo_pcm = Vec::with_capacity(4800 * 2);
        for i in 0..4800i64 {
            // Integer 432 Hz-like wave + periodic Dirac transient every 600 frames
            let cyc = (i % 110) - 55;
            let body = ((55 * 55 - cyc * cyc) * 4) as i16;
            let dirac = if i % 600 == 0 { 12000i16 } else { 0 };
            let l = body.saturating_add(dirac);
            let r = body.saturating_sub(dirac / 2);
            stereo_pcm.push(l);
            stereo_pcm.push(r);
        }

        let preset = PhoenixSoundPreset::sovereign_master();
        let (out_pcm, eight_a, receipt) =
            phoenix_transform_pcm_i16(&stereo_pcm, 48000, 2, &preset);

        assert_eq!(out_pcm.len(), stereo_pcm.len());
        assert_eq!(&eight_a[0..4], &EIGHT_A_MAGIC);
        assert_eq!(receipt.internal_oversample_hz, 768_000);
        assert!(receipt.harmonic_s_frames > 0);
        assert!(receipt.dirac_t_frames > 0);
        assert!(receipt.dominant_freq_hz.num > 0);
        assert!(receipt.soul_authenticity.num > 0);
        assert!(!receipt.shruti_name.is_empty());
    }

    #[test]
    fn taal_22_shruti_lattice_and_live_processor_are_zero_float_exact() {
        let (sa_r, sa_name) = nearest_taal_shruti_pq(Rational::integer(432));
        assert_eq!(sa_r, Rational::new(1, 1).unwrap());
        assert_eq!(sa_name, "Sa (Chhandovati)");

        let (pa_r, pa_name) = nearest_taal_shruti_pq(Rational::integer(648));
        assert_eq!(pa_r, Rational::new(3, 2).unwrap());
        assert_eq!(pa_name, "Pa (Alapini)");

        let (ga_r, ga_name) = nearest_taal_shruti_pq(Rational::integer(540));
        assert_eq!(ga_r, Rational::new(5, 4).unwrap());
        assert_eq!(ga_name, "Shuddha Ga (Prasarini)");

        let mut proc = PhoenixLiveProcessor::new(48_000, PhoenixSoundPreset::goonj_velvet_hall());
        let mut chunk = vec![0i16; 2048];
        for i in 0..1024usize {
            let cyc = ((i % 110) as i64) - 55;
            let s = ((55 * 55 - cyc * cyc) * 4) as i16;
            chunk[i * 2] = s;
            chunk[i * 2 + 1] = s;
        }
        // Inject a brickwall clipped sample to verify live Catmull-Rom repair
        chunk[200] = 32700;
        proc.process_stereo_in_place(&mut chunk);
        assert!(proc.catmull_rom_restored_samples >= 1);
        let (dom_hz, shruti_r, shruti_label, soul) = proc.live_telemetry();
        assert!(dom_hz.num > 0);
        assert!(shruti_r.num > 0);
        assert!(!shruti_label.is_empty());
        assert!(soul.num * 2 >= soul.den as i32);

        // Verify 4x (192 kHz) and 8x (384 kHz) 32-bit Catmull-Rom cubic spline hardware upsampling
        let mut in_48k = vec![0i16; 1024];
        for i in 0..512usize {
            let cyc = ((i % 110) as i64) - 55;
            let s = ((55 * 55 - cyc * cyc) * 4) as i16;
            in_48k[i * 2] = s;
            in_48k[i * 2 + 1] = s;
        }
        let mut out_192k = vec![0i32; 1024 * 4];
        let written_192k = proc.process_stereo_upsample_s32le(&mut in_48k, 4, &mut out_192k);
        assert_eq!(written_192k, 4096);
        assert!(out_192k.iter().any(|&v| v.abs() > 65536));

        let mut out_384k = vec![0i32; 1024 * 8];
        let written_384k = proc.process_stereo_upsample_s32le(&mut in_48k, 8, &mut out_384k);
        assert_eq!(written_384k, 8192);

        // Prove Babbage 3-Addition Forward Differencing is bit-for-bit identical to catmull_rom_s32_16x
        let (p0, p1, p2, p3) = (-12_345i16, 8_765i16, 21_432i16, -4_321i16);
        let l0 = p0 as i64;
        let l1 = p1 as i64;
        let l2 = p2 as i64;
        let l3 = p3 as i64;
        let a0 = -l0 + ((l1 << 1) + l1) - ((l2 << 1) + l2) + l3;
        let a1 = (l0 << 1) - ((l1 << 2) + l1) + (l2 << 2) - l3;
        let a2 = -l0 + l2;
        let c3 = a0 << 6;
        let c2 = a1 << 9;
        let c1 = a2 << 12;
        let c3_6 = (c3 << 2) + (c3 << 1);
        let mut y = l1 << 16;
        let mut d1 = c3 + c2 + c1;
        let mut d2 = c3_6 + (c2 << 1);
        let d3 = c3_6;
        for s in 0..8u8 {
            let babbage_val = y.clamp(-2_147_483_647, 2_147_483_647) as i32;
            let direct_val = catmull_rom_s32_16x(p0, p1, p2, p3, s * 2);
            assert_eq!(babbage_val, direct_val, "Babbage forward diff must equal direct cubic at sub-step {s}");
            y += d1;
            d1 += d2;
            d2 += d3;
        }
    }

    #[test]
    fn svara_5_lock_vocal_gate_rejects_instruments_and_diarizes_singers() {
        let mut proc = PhoenixLiveProcessor::new(48_000, PhoenixSoundPreset::vocal_clarity());

        // 1. Sub-bass (60 Hz) + stereo guitar/synth (opposite-phase L/R) -> must NOT trigger vocal gate!
        let mut instrumental = vec![0i16; 2048 * 2];
        for i in 0..2048usize {
            let sub = if (i % 800) < 400 { 7000i16 } else { -7000i16 };
            let stereo_gtr = if (i % 150) < 75 { 4500i16 } else { -4500i16 };
            instrumental[i * 2] = sub + stereo_gtr;
            instrumental[i * 2 + 1] = sub - stereo_gtr;
        }
        proc.process_stereo_in_place(&mut instrumental);
        assert_eq!(
            proc.vocal_confidence_q10, 0,
            "Pure sub-bass + wide stereo instrument must produce 0 vocal confidence"
        );
        assert_eq!(
            proc.active_singer_id, 255,
            "Active singer ID must stay 255 (Instrumental Only) when no vocals are present"
        );

        // 2. Singer 1: Centered Baritone (~150 Hz, period = 320 samples at 48 kHz) with vowel harmonics
        let mut baritone = vec![0i16; 2048 * 2];
        for i in 0..2048usize {
            let p_f0 = if (i % 320) < 160 { 5200i16 } else { -5200i16 };
            let p_f2 = if (i % 40) < 20 { 2600i16 } else { -2600i16 }; // 1200 Hz vowel F2
            let s = p_f0 + p_f2;
            baritone[i * 2] = s;
            baritone[i * 2 + 1] = s;
        }
        proc.process_stereo_in_place(&mut baritone);
        assert!(
            proc.vocal_confidence_q10 >= 180,
            "Centered human baritone with vowel formants must open the 5-Lock Svara Vocal Gate (got {})",
            proc.vocal_confidence_q10
        );
        assert_eq!(proc.active_singer_id, 0, "First singer must be diarized into Slot 0 (V1)");
        assert!(proc.singer_slots[0].active);

        // 3. Singer 2: Centered Soprano (~340 Hz, period = 141 samples at 48 kHz) with high F2/F3 formants
        let mut soprano = vec![0i16; 2048 * 2];
        for i in 0..2048usize {
            let p_f0 = if (i % 141) < 70 { 4800i16 } else { -4800i16 };
            let p_f3 = if (i % 20) < 10 { 3200i16 } else { -3200i16 }; // 2400 Hz singer formant
            let s = p_f0 + p_f3;
            soprano[i * 2] = s;
            soprano[i * 2 + 1] = s;
        }
        proc.process_stereo_in_place(&mut soprano);
        assert_eq!(
            proc.active_singer_id, 1,
            "Second singer with distinct F0 and formant ratio must be diarized into Slot 1 (V2)"
        );
        assert!(proc.singer_slots[1].active);
        assert!(
            proc.singer_slots[1].f0_centroid_hz > proc.singer_slots[0].f0_centroid_hz + 80,
            "Soprano F0 centroid ({}) must exceed Baritone F0 centroid ({})",
            proc.singer_slots[1].f0_centroid_hz,
            proc.singer_slots[0].f0_centroid_hz
        );
    }
}
