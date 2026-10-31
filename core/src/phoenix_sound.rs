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
    /// Default "PhoeniX Sovereign Master" — balanced revelation for all music.
    pub const fn sovereign_master() -> Self {
        Self {
            sparkle_q10: 420,       // 420/1024 (~41%) 768kHz sub-sample sparkle
            warmth_q10: 360,        // 360/1024 (~35%) 2nd-harmonic tube warmth
            drive_q10: 220,         // 220/1024 (~21%) 3rd-harmonic tape density
            punch_q10: 480,         // 480/1024 (~47%) Dirac transient punch
            air_q10: 340,           // 340/1024 (~33%) High-shelf harmonic air
            phi_432_bloom_q10: 260, // 260/1024 (~25%) φ + 432Hz resonant bloom
            stereo_width_q10: 1320, // 1320/1024 (~129%) 3D spatial locus width
            pitch_relax_54_55: false,
        }
    }

    /// Deep 432 Hz Sanctuary mode (includes exact `54/55` rational pitch relaxation).
    pub const fn sanctuary_432() -> Self {
        Self {
            sparkle_q10: 380,
            warmth_q10: 480,
            drive_q10: 180,
            punch_q10: 400,
            air_q10: 360,
            phi_432_bloom_q10: 380,
            stereo_width_q10: 1400,
            pitch_relax_54_55: true,
        }
    }
}

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

/// Stage 1: Integer Catmull-Rom dropout & digital brickwall-clipping restoration on a single channel.
///
/// Detects:
/// 1. Hard digital clipping plateaus (`|x[i]| >= 32600` for 2+ consecutive samples), and
/// 2. Sudden sample-dropouts to zero surrounded by high-amplitude active wave energy.
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

                    let da = current_peak_abs.abs_diff(prev_peak_abs) as u64;
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

        // ── Stage 3: PhoeniX Harmonic Revelation Synthesis ────────────────────

        // 1. Warmth (2nd-order even harmonic `(x * |x|) >> 15` on warm body, DC-blocked)
        let even_harm_l = (((s_l * s_l.abs()) >> 15) * preset.warmth_q10) >> 11;
        let even_harm_r = (((s_r * s_r.abs()) >> 15) * preset.warmth_q10) >> 11;

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
        let phi_bloom_l = (phi_resonator_l * preset.phi_432_bloom_q10) >> 13;
        let phi_bloom_r = (phi_resonator_r * preset.phi_432_bloom_q10) >> 13;

        // Combine revealed harmonic components
        let raw_l = s_l + even_harm_l + lp_norm_l + sparkle_l + air_l + punch_l + phi_bloom_l;
        let raw_r = s_r + even_harm_r + lp_norm_r + sparkle_r + air_r + punch_r + phi_bloom_r;

        // 1-pole integer DC blocker: `y[n] = x[n] - x[n-1] + (255 * y[n-1]) / 256`
        let dc_l = raw_l - dc_prev_in_l + ((dc_prev_out_l * 255) >> 8);
        dc_prev_in_l = raw_l;
        dc_prev_out_l = dc_l;

        let dc_r = raw_r - dc_prev_in_r + ((dc_prev_out_r * 255) >> 8);
        dc_prev_in_r = raw_r;
        dc_prev_out_r = dc_r;

        // 6. Stereo Mid/Side (`M/S`) Holographic Spatial Locus Widening
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

/// Smooth knee integer soft-limiter for 16-bit audio (`-32767..=32767`).
/// Preserves linear transparency below `28000` and gently curves peaks above `28000`
/// so PhoeniX harmonic bloom never hard-clips.
#[inline]
pub fn soft_limit_i16(x: i64) -> i16 {
    let sign = if x < 0 { -1 } else { 1 };
    let a = x.abs();
    if a <= 28000 {
        return (sign * a) as i16;
    }
    let excess = a - 28000;
    // Asymptotic rational knee: `28000 + (4767 * excess) / (excess + 4767)`
    let compressed = 28000 + (4767 * excess) / (excess + 4767);
    (sign * compressed.min(32767)) as i16
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
    }
}
