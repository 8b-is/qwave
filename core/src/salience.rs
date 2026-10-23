//! Zero-Float Integer-Sovereign Acoustic Salience & `MEM|8` Speech Learning Engine (`qwave_core::salience`).
//!
//! 100% integer and `Rational` (`p/q`) math — zero floating-point instructions.
//!
//! Architecture:
//! 1. [`MarineIntDetector`]: Integer-sovereign port of the Marine Algorithm
//!    ("A Universal Salience Primitive for Multimodal Attention"). Tracks peak-to-peak
//!    fundamental vocal periods (`50 Hz ..= 640 Hz`) and amplitude/period jitter using
//!    exact Q8/Q15 fixed-point integer arithmetic.
//! 2. [`extract_salient_grains`]: Scans incoming `16-bit PCM` user speech in `20 ms`
//!    windows, ranks every window by its Marine salience score, and extracts the
//!    **Top-K Highest-Salience Vocal Grains** — each crystallized into a 79-byte
//!    [`WaveInt`] `MEM|8` frame with exact `p/q` [`Rational`] fundamental frequency `F0`
//!    and [`VadPq`] emotional ternary code.
//! 3. [`combine_salient_speech_wav`]: Uses the user's accumulated `MEM|8`
//!    [`SpeakerSalienceProfile`] (highest-salience vocal grain + 16-point prosody
//!    envelope + harmonic warmth) to modulate and enrich outgoing TTS `16-bit PCM`
//!    speech in pure integer DSP — so the system learns how to talk from the
//!    most salient parts of the user's voice.

use crate::Rational;
use crate::quanttern::{VadPq, default_threshold_pq, pack_vad_pq_byte};
use crate::wave::{WaveInt, WaveProvenance};

/// Q15 unity scale (`32767` represents `1.0`).
pub const Q15_ONE: i32 = 32_767;

/// Default clipping/noise gate in Q15 (`66 / 32768` ≈ `0.2%`, matching Marine `0.002`).
pub const DEFAULT_CLIP_THRESHOLD_Q15: i32 = 66;

/// Zero-float Integer Marine Salience Detector.
#[derive(Clone, Debug)]
pub struct MarineIntDetector {
    clip_threshold: i32,
    sample_rate: u32,
    min_period_ticks: usize,
    max_period_ticks: usize,
    prev_sample: i32,
    prev_prev_sample: i32,
    last_peak_index: usize,
    /// Exponential Moving Average of peak amplitude in Q8 (`amp << 8`).
    ema_amp_q8: i64,
    /// Exponential Moving Average of peak period (in sample ticks) in Q8 (`period << 8`).
    ema_period_q8: i64,
    /// Accumulated period ticks and peak count for exact `p/q` `F0` calculation.
    total_period_ticks: u64,
    valid_peaks: u64,
    total_jitter_q8: u64,
    /// Glottal-cycle sustained vocal resonance in Q15 (decays by `63/64` per sample between glottal peaks).
    vocal_resonance_q15: i32,
}

impl MarineIntDetector {
    /// Create a new detector for the given `sample_rate` (e.g., `16_000` or `24_000` Hz).
    pub fn new(sample_rate: u32, clip_threshold: i32) -> Self {
        let sr = sample_rate.max(8_000) as usize;
        // Human vocal biometric resonance filter: 50 Hz ..= 640 Hz
        let min_period_ticks = (sr / 640).max(4);
        let max_period_ticks = (sr / 50).max(min_period_ticks + 1);
        Self {
            clip_threshold: clip_threshold.max(1),
            sample_rate: sr as u32,
            min_period_ticks,
            max_period_ticks,
            prev_sample: 0,
            prev_prev_sample: 0,
            last_peak_index: 0,
            ema_amp_q8: 0,
            ema_period_q8: 0,
            total_period_ticks: 0,
            valid_peaks: 0,
            total_jitter_q8: 0,
            vocal_resonance_q15: 0,
        }
    }

    /// Process a single `i16` PCM sample and return its instant salience score in Q15 (`0..=32767`).
    #[inline]
    pub fn process_sample_i16(&mut self, sample: i16, index: usize) -> u16 {
        let s = sample as i32;
        let abs_s = s.abs().min(Q15_ONE);
        // Natural glottal-cycle decay (`63/64` per sample)
        self.vocal_resonance_q15 = (self.vocal_resonance_q15 * 63) >> 6;
        let mut salience_q15: i32 = 0;

        if abs_s >= self.clip_threshold {
            let energy_q15 = abs_s;
            let is_peak = self.prev_prev_sample <= self.prev_sample && self.prev_sample > s && self.prev_sample > 0;

            if is_peak {
                let current_peak_idx = index.saturating_sub(1);
                let period_ticks = current_peak_idx.saturating_sub(self.last_peak_index);

                if (self.min_period_ticks..=self.max_period_ticks).contains(&period_ticks) {
                    let amp = self.prev_sample.abs().min(Q15_ONE) as i64;
                    let amp_q8 = amp << 8;
                    let period_q8 = (period_ticks as i64) << 8;

                    if self.last_peak_index == 0 || self.valid_peaks == 0 {
                        self.ema_amp_q8 = amp_q8;
                        self.ema_period_q8 = period_q8;
                    } else {
                        // Exact integer EMA with alpha = 1/8 (`>> 3`):
                        // new_ema = (7 * old_ema + sample_q8) >> 3
                        self.ema_amp_q8 = ((self.ema_amp_q8 * 7) + amp_q8) >> 3;
                        self.ema_period_q8 = ((self.ema_period_q8 * 7) + period_q8) >> 3;
                    }

                    let jitter_p_q8 = (period_q8 - self.ema_period_q8).unsigned_abs();
                    // Normalize amplitude shimmer to tick-scale (`>> 9` maps Q15<<8 down to tick units<<8)
                    let jitter_a_q8 = (amp_q8 - self.ema_amp_q8).unsigned_abs() >> 9;
                    let total_jitter_q8 = jitter_p_q8.saturating_add(jitter_a_q8);

                    // Integer harmonic stability: `Q15_ONE * 256 / (256 + total_jitter_q8)`
                    let jitter_contrib_q15 =
                        ((Q15_ONE as u64) * 256 / (256 + total_jitter_q8)) as i32;

                    // Marine weighting: 2/5 (0.4) energy + 3/5 (0.6) vocal stability
                    salience_q15 = (energy_q15 * 2 + jitter_contrib_q15 * 3) / 5;
                    self.vocal_resonance_q15 = salience_q15;

                    self.last_peak_index = current_peak_idx;
                    self.total_period_ticks += period_ticks as u64;
                    self.valid_peaks += 1;
                    self.total_jitter_q8 += total_jitter_q8;
                } else {
                    salience_q15 = (energy_q15 / 10).max(self.vocal_resonance_q15);
                }
            } else {
                salience_q15 = (energy_q15 / 10).max(self.vocal_resonance_q15);
            }
        }

        self.prev_prev_sample = self.prev_sample;
        self.prev_sample = s;
        salience_q15.clamp(0, Q15_ONE) as u16
    }

    /// Exact `p/q` fundamental frequency `F0` in Hz (`sample_rate * valid_peaks / total_period_ticks`).
    pub fn f0_hz_pq(&self) -> Rational {
        if self.valid_peaks == 0 || self.total_period_ticks == 0 {
            return Rational::integer(156); // Default human vocal reference (156 Hz)
        }
        let num = (self.sample_rate as u64).saturating_mul(self.valid_peaks);
        let den = self.total_period_ticks;
        // Scale down safely if needed so both fit in i32/u32
        let mut n = num;
        let mut d = den;
        while n > (i32::MAX as u64) || d > (u32::MAX as u64) {
            n >>= 1;
            d = (d >> 1).max(1);
        }
        Rational::new(n as i32, d as u32).unwrap_or_else(|| Rational::integer(156))
    }
}

/// A single high-salience vocal grain extracted from the user's incoming audio.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SalientGrain {
    /// Start offset in samples within the utterance.
    pub start_sample: usize,
    /// Duration of this grain in milliseconds.
    pub duration_ms: u32,
    /// Average Marine salience score in Q15 (`0..=32767`).
    pub salience_q15: u16,
    /// Exact `p/q` Marine salience ratio (`salience_q15 / 32767`).
    pub salience_pq: Rational,
    /// Exact `p/q` fundamental frequency `F0` in Hz during this vocal grain.
    pub f0_hz: Rational,
    /// Peak amplitude in Q15 (`0..=32767`).
    pub peak_amp_q15: u16,
    /// 16-bin prosodic amplitude contour of this grain in Q15.
    pub envelope_q15: [u16; 16],
    /// Zero-float emotional ternary reading (`VadPq`) and gate-coded byte.
    pub vad_pq: VadPq,
    pub vad_byte: u8,
    /// Crystallized 79-byte `MEM|8` `WaveInt` binary frame for this vocal grain.
    pub wave: WaveInt,
    /// Raw `i16` PCM samples of this high-salience vocal grain.
    pub pcm: Vec<i16>,
}

/// Summary of all salient vocal grains extracted from an utterance.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UtteranceSalienceReport {
    pub sample_rate: u32,
    pub total_samples: usize,
    pub duration_ms: u32,
    pub overall_f0_hz: Rational,
    pub overall_salience_pq: Rational,
    pub overall_vad_byte: u8,
    pub salient_frame_ratio_pq: Rational,
    pub top_grains: Vec<SalientGrain>,
}

/// Extract the Top-K highest-salience vocal grains (`60 ms` grains = 3 consecutive `20 ms` frames)
/// from `i16` PCM audio using 100% integer-sovereign math.
pub fn extract_salient_grains(
    samples: &[i16],
    sample_rate: u32,
    top_k: usize,
    now_epoch: u64,
) -> UtteranceSalienceReport {
    let sr = sample_rate.max(8_000);
    let grain_samples = ((sr as usize) * 60 / 1000).max(256); // 60ms vocal grain
    let duration_ms = ((samples.len() as u64) * 1000 / (sr as u64)) as u32;

    if samples.is_empty() {
        return UtteranceSalienceReport {
            sample_rate: sr,
            total_samples: 0,
            duration_ms: 0,
            overall_f0_hz: Rational::integer(156),
            overall_salience_pq: Rational::ZERO,
            overall_vad_byte: 0x55,
            salient_frame_ratio_pq: Rational::ZERO,
            top_grains: Vec::new(),
        };
    }

    let mut global_detector = MarineIntDetector::new(sr, DEFAULT_CLIP_THRESHOLD_Q15);
    let mut all_grains: Vec<SalientGrain> = Vec::new();
    let mut salient_count = 0u32;
    let mut total_chunks = 0u32;
    let mut sum_salience_q15: u64 = 0;

    for (chunk_idx, chunk) in samples.chunks(grain_samples).enumerate() {
        if chunk.len() < grain_samples / 2 {
            break;
        }
        total_chunks += 1;
        let start_sample = chunk_idx * grain_samples;

        let mut local_detector = MarineIntDetector::new(sr, DEFAULT_CLIP_THRESHOLD_Q15);
        let mut chunk_salience_sum: u64 = 0;
        let mut peak_amp: u16 = 0;

        for (i, &s) in chunk.iter().enumerate() {
            let abs_u16 = (s as i32).abs().min(Q15_ONE) as u16;
            if abs_u16 > peak_amp {
                peak_amp = abs_u16;
            }
            let sal = local_detector.process_sample_i16(s, i);
            let _ = global_detector.process_sample_i16(s, start_sample + i);
            chunk_salience_sum += sal as u64;
        }

        let avg_sal_q15 = (chunk_salience_sum / (chunk.len() as u64)).min(Q15_ONE as u64) as u16;
        sum_salience_q15 += avg_sal_q15 as u64;

        // Salience gate: >= 16 / 32767 (~0.0005 in Marine units) and at least 1 valid vocal pitch peak
        if avg_sal_q15 >= 16 && local_detector.valid_peaks > 0 {
            salient_count += 1;
            let envelope_q15 = compute_16bin_envelope_q15(chunk);
            let f0_hz = local_detector.f0_hz_pq();
            let salience_pq =
                Rational::new(avg_sal_q15 as i32, Q15_ONE as u32).unwrap_or(Rational::ZERO);

            // Derive zero-float VadPq from acoustic harmony (valence), peak energy (arousal), and pitch lock (dominance)
            let valence_pq =
                Rational::new((avg_sal_q15 as i32) * 4, Q15_ONE as u32).unwrap_or(Rational::ZERO);
            let arousal_pq = Rational::new((peak_amp as i32) * 2 - Q15_ONE, Q15_ONE as u32)
                .unwrap_or(Rational::ZERO);
            let dominance_pq = Rational::new(
                (local_detector.valid_peaks.min(16) as i32) - 4,
                12,
            )
            .unwrap_or(Rational::ZERO);

            let vad_pq = VadPq::new(valence_pq, arousal_pq, dominance_pq);
            let vad_byte = pack_vad_pq_byte(vad_pq, default_threshold_pq());

            let hash = fnv1a_pcm_i16(chunk);
            let amp_pq =
                Rational::new(peak_amp.max(1) as i32, Q15_ONE as u32).unwrap_or(Rational::ONE);
            let phase_pq = Rational::new((start_sample % 628) as i32, 100).unwrap_or(Rational::ZERO);

            let wave = WaveInt {
                base_amplitude: amp_pq,
                frequency: f0_hz,
                phase: phase_pq,
                emotional_valence: vad_pq.valence,
                arousal: vad_pq.arousal,
                created_at: now_epoch,
                last_accessed: now_epoch,
                access_count: 1,
                decay_rate: Rational::integer(7200),
                id: Some(hash),
                provenance: WaveProvenance::Cognitive,
            };

            all_grains.push(SalientGrain {
                start_sample,
                duration_ms: 60,
                salience_q15: avg_sal_q15,
                salience_pq,
                f0_hz,
                peak_amp_q15: peak_amp,
                envelope_q15,
                vad_pq,
                vad_byte,
                wave,
                pcm: chunk.to_vec(),
            });
        }
    }

    // Sort highest salience first (tie-breaking on peak vocal amplitude)
    all_grains.sort_by(|a, b| {
        b.salience_q15
            .cmp(&a.salience_q15)
            .then_with(|| b.peak_amp_q15.cmp(&a.peak_amp_q15))
    });
    all_grains.truncate(top_k.max(1));

    let overall_f0_hz = global_detector.f0_hz_pq();
    let avg_overall_sal = if total_chunks > 0 {
        (sum_salience_q15 / (total_chunks as u64)) as i32
    } else {
        0
    };
    let overall_salience_pq =
        Rational::new(avg_overall_sal, Q15_ONE as u32).unwrap_or(Rational::ZERO);
    let salient_frame_ratio_pq =
        Rational::new(salient_count as i32, total_chunks.max(1)).unwrap_or(Rational::ZERO);
    let overall_vad_byte = all_grains.first().map(|g| g.vad_byte).unwrap_or(0x55);

    UtteranceSalienceReport {
        sample_rate: sr,
        total_samples: samples.len(),
        duration_ms,
        overall_f0_hz,
        overall_salience_pq,
        overall_vad_byte,
        salient_frame_ratio_pq,
        top_grains: all_grains,
    }
}

/// Compute a 16-bin amplitude envelope in Q15 (`0..=32767`) using pure integer math.
pub fn compute_16bin_envelope_q15(samples: &[i16]) -> [u16; 16] {
    let mut env = [0u16; 16];
    if samples.is_empty() {
        return env;
    }
    let bin_len = (samples.len() / 16).max(1);
    for (b, slot) in env.iter_mut().enumerate() {
        let start = (b * bin_len).min(samples.len());
        let end = ((b + 1) * bin_len).min(samples.len());
        if start >= end {
            *slot = 4096;
            continue;
        }
        let mut sum: u64 = 0;
        for &s in &samples[start..end] {
            sum += (s as i32).abs().min(Q15_ONE) as u64;
        }
        *slot = (sum / ((end - start) as u64)).min(Q15_ONE as u64) as u16;
    }
    env
}

fn fnv1a_pcm_i16(samples: &[i16]) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for &s in samples {
        for b in s.to_le_bytes() {
            hash ^= b as u64;
            hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
        }
    }
    hash
}

/// Decode a 16-bit mono PCM WAV byte buffer into `(sample_rate, Vec<i16>)` in pure integer Rust.
pub fn decode_wav_i16(wav_bytes: &[u8]) -> Option<(u32, Vec<i16>)> {
    if wav_bytes.len() < 44 || &wav_bytes[0..4] != b"RIFF" || &wav_bytes[8..12] != b"WAVE" {
        return None;
    }
    let mut pos = 12usize;
    let mut sample_rate = 16_000u32;
    let mut channels = 1u16;
    let mut bits_per_sample = 16u16;

    while pos + 8 <= wav_bytes.len() {
        let chunk_id = &wav_bytes[pos..pos + 4];
        let chunk_size = u32::from_le_bytes([
            wav_bytes[pos + 4],
            wav_bytes[pos + 5],
            wav_bytes[pos + 6],
            wav_bytes[pos + 7],
        ]) as usize;
        pos += 8;
        if pos + chunk_size > wav_bytes.len() {
            break;
        }
        if chunk_id == b"fmt " && chunk_size >= 16 {
            channels = u16::from_le_bytes([wav_bytes[pos + 2], wav_bytes[pos + 3]]).max(1);
            sample_rate = u32::from_le_bytes([
                wav_bytes[pos + 4],
                wav_bytes[pos + 5],
                wav_bytes[pos + 6],
                wav_bytes[pos + 7],
            ]);
            bits_per_sample = u16::from_le_bytes([wav_bytes[pos + 14], wav_bytes[pos + 15]]);
        } else if chunk_id == b"data" && bits_per_sample == 16 {
            let data = &wav_bytes[pos..pos + chunk_size];
            let step = (channels as usize) * 2;
            let mut out = Vec::with_capacity(data.len() / step.max(2));
            let mut i = 0;
            while i + 1 < data.len() {
                out.push(i16::from_le_bytes([data[i], data[i + 1]]));
                i += step.max(2);
            }
            return Some((sample_rate, out));
        }
        pos += chunk_size + (chunk_size & 1);
    }
    None
}

/// Encode `i16` mono PCM samples into a standard 44-byte RIFF WAVE buffer.
pub fn encode_wav_i16(sample_rate: u32, samples: &[i16]) -> Vec<u8> {
    let data_bytes = (samples.len() * 2) as u32;
    let total_len = 36 + data_bytes;
    let mut out = Vec::with_capacity(44 + samples.len() * 2);
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&total_len.to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes()); // PCM = 1
    out.extend_from_slice(&1u16.to_le_bytes()); // Mono = 1
    out.extend_from_slice(&sample_rate.to_le_bytes());
    out.extend_from_slice(&(sample_rate * 2).to_le_bytes());
    out.extend_from_slice(&2u16.to_le_bytes());
    out.extend_from_slice(&16u16.to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(&data_bytes.to_le_bytes());
    for &s in samples {
        out.extend_from_slice(&s.to_le_bytes());
    }
    out
}

/// Learned `MEM|8` speaker salience & prosody profile accumulated from the user's highest-salience audio grains.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SpeakerSalienceProfile {
    pub f0_hz: Rational,
    pub avg_salience: Rational,
    pub vad_byte: u8,
    pub grains_learned: u64,
    pub prosody_envelope_q15: [u16; 16],
    /// The highest-salience resonant vocal grain (`i16` PCM) captured from the user.
    pub best_grain_pcm: Vec<i16>,
}

impl Default for SpeakerSalienceProfile {
    fn default() -> Self {
        Self {
            f0_hz: Rational::integer(156),
            avg_salience: Rational::new(1, 4).unwrap_or(Rational::ZERO),
            vad_byte: 0x55,
            grains_learned: 0,
            prosody_envelope_q15: [16_384; 16],
            best_grain_pcm: Vec::new(),
        }
    }
}

impl SpeakerSalienceProfile {
    /// Fold a new [`UtteranceSalienceReport`] into the persistent `MEM|8` speaker profile
    /// using 100% integer running averages.
    pub fn absorb_report(&mut self, report: &UtteranceSalienceReport) {
        let Some(best) = report.top_grains.first() else {
            return;
        };

        if self.grains_learned == 0 {
            self.f0_hz = report.overall_f0_hz;
            self.avg_salience = best.salience_pq;
            self.vad_byte = best.vad_byte;
            self.prosody_envelope_q15 = best.envelope_q15;
            self.best_grain_pcm = best.pcm.clone();
            self.grains_learned = report.top_grains.len() as u64;
            return;
        }

        // Integer running average of F0 Hz (3/4 old + 1/4 new)
        let old_f0 = (self.f0_hz.num as i64) / (self.f0_hz.den.max(1) as i64);
        let new_f0 = (report.overall_f0_hz.num as i64) / (report.overall_f0_hz.den.max(1) as i64);
        let blended_f0 = ((old_f0 * 3 + new_f0) >> 2).clamp(60, 500) as i32;
        self.f0_hz = Rational::integer(blended_f0);

        for (i, slot) in self.prosody_envelope_q15.iter_mut().enumerate() {
            *slot = (((*slot as u32) * 3 + (best.envelope_q15[i] as u32)) >> 2) as u16;
        }

        self.avg_salience = best.salience_pq;
        self.vad_byte = best.vad_byte;
        if best.pcm.len() >= 128 {
            self.best_grain_pcm = best.pcm.clone();
        }
        self.grains_learned = self
            .grains_learned
            .saturating_add(report.top_grains.len() as u64);
    }

    /// Serialize the learned `MEM|8` speaker salience profile into a compact deterministic binary frame.
    pub fn to_bytes(&self) -> Vec<u8> {
        let grain_len = self.best_grain_pcm.len().min(4096);
        let mut out = Vec::with_capacity(64 + grain_len * 2);
        out.extend_from_slice(b"M8SP");
        out.extend_from_slice(&self.f0_hz.num.to_le_bytes());
        out.extend_from_slice(&self.f0_hz.den.to_le_bytes());
        out.extend_from_slice(&self.avg_salience.num.to_le_bytes());
        out.extend_from_slice(&self.avg_salience.den.to_le_bytes());
        out.push(self.vad_byte);
        out.extend_from_slice(&self.grains_learned.to_le_bytes());
        for &e in &self.prosody_envelope_q15 {
            out.extend_from_slice(&e.to_le_bytes());
        }
        out.extend_from_slice(&(grain_len as u32).to_le_bytes());
        for &s in &self.best_grain_pcm[..grain_len] {
            out.extend_from_slice(&s.to_le_bytes());
        }
        out
    }

    /// Restore a learned `MEM|8` speaker salience profile from its binary frame.
    pub fn from_bytes(bytes: &[u8]) -> Option<Self> {
        if bytes.len() < 65 || &bytes[0..4] != b"M8SP" {
            return None;
        }
        let f0_num = i32::from_le_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]);
        let f0_den = u32::from_le_bytes([bytes[8], bytes[9], bytes[10], bytes[11]]).max(1);
        let sal_num = i32::from_le_bytes([bytes[12], bytes[13], bytes[14], bytes[15]]);
        let sal_den = u32::from_le_bytes([bytes[16], bytes[17], bytes[18], bytes[19]]).max(1);
        let vad_byte = bytes[20];
        let grains_learned = u64::from_le_bytes([
            bytes[21], bytes[22], bytes[23], bytes[24], bytes[25], bytes[26], bytes[27], bytes[28],
        ]);
        let mut prosody_envelope_q15 = [16_384u16; 16];
        for (i, slot) in prosody_envelope_q15.iter_mut().enumerate() {
            let off = 29 + i * 2;
            *slot = u16::from_le_bytes([bytes[off], bytes[off + 1]]);
        }
        let grain_len = u32::from_le_bytes([bytes[61], bytes[62], bytes[63], bytes[64]]) as usize;
        if bytes.len() < 65 + grain_len * 2 {
            return None;
        }
        let mut best_grain_pcm = Vec::with_capacity(grain_len);
        for i in 0..grain_len {
            let off = 65 + i * 2;
            best_grain_pcm.push(i16::from_le_bytes([bytes[off], bytes[off + 1]]));
        }
        Some(Self {
            f0_hz: Rational::new(f0_num, f0_den).unwrap_or_else(|| Rational::integer(156)),
            avg_salience: Rational::new(sal_num, sal_den).unwrap_or(Rational::ZERO),
            vad_byte,
            grains_learned,
            prosody_envelope_q15,
            best_grain_pcm,
        })
    }
}

/// Combine the user's learned `MEM|8` highest-salience vocal profile into an outgoing TTS WAV
/// using 100% integer (`i16`/`i32`/`i64`) DSP:
/// 1. Modulates the speech dynamic cadence envelope using the user's 16-bin salient prosody contour.
/// 2. Phase-locks a subtle (`1/24` amplitude) harmonic resonance overtone from the user's
///    highest-salience vocal grain (`best_grain_pcm`) onto voiced peaks so the system's voice
///    carries the user's own acoustic warmth and cadence.
pub fn combine_salient_speech_wav(tts_wav: &[u8], profile: &SpeakerSalienceProfile) -> Vec<u8> {
    if profile.grains_learned == 0 {
        return tts_wav.to_vec();
    }
    let Some((sample_rate, mut samples)) = decode_wav_i16(tts_wav) else {
        return tts_wav.to_vec();
    };
    if samples.is_empty() {
        return tts_wav.to_vec();
    }

    let total = samples.len();
    let grain = &profile.best_grain_pcm;
    let has_grain = grain.len() >= 64;

    // Normalize the 16-bin prosody contour around Q15_ONE (32767)
    let avg_env: u32 = profile
        .prosody_envelope_q15
        .iter()
        .map(|&v| v as u32)
        .sum::<u32>()
        / 16;
    let avg_env = avg_env.max(1024);

    let mut prev_s: i32 = 0;
    for (i, sample) in samples.iter_mut().enumerate() {
        let bin = (i * 16 / total).min(15);
        let env_target = profile.prosody_envelope_q15[bin] as u32;
        // Prosodic gain in Q10 (1024 = 1.0x), bounded to [896..=1184] (~0.88x .. 1.15x)
        // so cadence inflection is natural and never distorts
        let raw_gain_q10 = (env_target * 1024 / avg_env).clamp(640, 1408);
        // Blend 7/8 base + 1/8 learned prosody contour (`>> 3`)
        let gain_q10 = ((1024 * 7 + raw_gain_q10) >> 3) as i32;

        let s = (*sample as i32 * gain_q10) >> 10;

        // Subtle salient grain harmonic warmth on voiced regions (`|s| > 512`)
        let harmonic = if has_grain && s.abs() > 512 {
            let g_sample = grain[i % grain.len()] as i32;
            // Scale salient grain by current voiced envelope (`|s| / 32767`) at 1/24th blend
            (g_sample * s.abs()) / (Q15_ONE * 24)
        } else {
            0
        };

        // Gentle integer 1-pole warmth smoothing (`7/8 current + 1/8 prev`)
        let combined = s + harmonic;
        let smoothed = (combined * 7 + prev_s) >> 3;
        prev_s = smoothed;

        *sample = smoothed.clamp(-Q15_ONE, Q15_ONE) as i16;
    }

    encode_wav_i16(sample_rate, &samples)
}

/// Classification of the acoustic source in the room, computed in 100% integer math.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AcousticSourceKind {
    /// Non-vocal background noise, keyboard clicks, fan hum, or silence.
    AmbientNoise,
    /// The primary enrolled user ("Hue") matching `primary_profile`.
    PrimaryUser,
    /// Another distinct human voice in the room (`0..=3` = Friend 1..4).
    OtherSpeaker(u8),
    /// System's own TTS output playing over the speaker.
    SystemEcho,
}

impl AcousticSourceKind {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::AmbientNoise => "ambient_noise",
            Self::PrimaryUser => "hue",
            Self::OtherSpeaker(0) => "friend_1",
            Self::OtherSpeaker(1) => "friend_2",
            Self::OtherSpeaker(2) => "friend_3",
            Self::OtherSpeaker(_) => "friend_4",
            Self::SystemEcho => "system_echo",
        }
    }
}

/// Conversational context in the room: is the user addressing the AI, or chatting with a friend next to them?
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InteractionContext {
    /// Silence, ambient noise, or system echo.
    SilentOrNoise,
    /// Primary user ("Hue") is addressing the AI (on-axis or using wake/direct address).
    AddressingAgent,
    /// Primary user ("Hue") is chatting with a friend next to him (dyadic turn-taking or off-axis side chat).
    ChattingWithFriend,
    /// A friend / other person in the room is speaking.
    FriendSpeaking,
}

impl InteractionContext {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::SilentOrNoise => "silent_or_noise",
            Self::AddressingAgent => "addressing_agent",
            Self::ChattingWithFriend => "chatting_with_friend",
            Self::FriendSpeaking => "friend_speaking",
        }
    }
}

/// Complete zero-float acoustic diarization & room context result for an audio window.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RoomUtteranceAnalysis {
    pub source: AcousticSourceKind,
    pub context: InteractionContext,
    /// Similarity to the primary user (`0..=32767` in Q15).
    pub primary_similarity_q15: u16,
    /// Ratio of current utterance peak/envelope energy to primary user's on-axis baseline (`0..=32767` in Q15).
    pub on_axis_ratio_q15: u16,
    /// Whether the AI agent should actively respond (`true` only when `AddressingAgent`).
    pub should_agent_respond: bool,
    pub salience_report: UtteranceSalienceReport,
}

/// Compute integer speaker similarity in Q15 (`0..=32767`) between a learned [`SpeakerSalienceProfile`]
/// and an incoming [`UtteranceSalienceReport`] using:
/// 1. Fundamental pitch (`f0_hz`) integer distance (`|f0_a - f0_b|`)
/// 2. 16-bin normalized prosody contour L1 distance
pub fn speaker_similarity_q15(
    profile: &SpeakerSalienceProfile,
    report: &UtteranceSalienceReport,
) -> u16 {
    let Some(best) = report.top_grains.first() else {
        return 0;
    };
    if profile.grains_learned == 0 {
        return 28_000;
    }

    let prof_f0 = (profile.f0_hz.num / (profile.f0_hz.den.max(1) as i32)).clamp(50, 640);
    let utt_f0 = (report.overall_f0_hz.num / (report.overall_f0_hz.den.max(1) as i32)).clamp(50, 640);
    let f0_diff = (prof_f0 - utt_f0).abs();

    // Pitch similarity in Q15: 0 Hz diff -> 32767; >= 110 Hz diff -> 0
    let pitch_sim_q15 = if f0_diff >= 110 {
        0
    } else {
        ((110 - f0_diff) * Q15_ONE) / 110
    };

    // Normalized 16-bin prosody contour L1 similarity
    let prof_sum: i32 = profile.prosody_envelope_q15.iter().map(|&x| x as i32).sum::<i32>().max(16);
    let utt_sum: i32 = best.envelope_q15.iter().map(|&x| x as i32).sum::<i32>().max(16);
    let mut l1_diff_q12: i32 = 0;
    for i in 0..16 {
        let p_norm = (profile.prosody_envelope_q15[i] as i32 * 4096) / prof_sum;
        let u_norm = (best.envelope_q15[i] as i32 * 4096) / utt_sum;
        l1_diff_q12 += (p_norm - u_norm).abs();
    }
    let env_sim_q15 = ((4096 - l1_diff_q12.min(4096)) * Q15_ONE) / 4096;

    // Weighted combination: 3/4 pitch identity + 1/4 prosodic cadence identity
    (((pitch_sim_q15 * 3) + env_sim_q15) >> 2).clamp(0, Q15_ONE) as u16
}

/// Multi-speaker room state & conversational context tracker in 100% integer math.
/// Distinguishes:
/// - Primary User ("Hue") addressing the AI (`AddressingAgent`)
/// - Primary User ("Hue") chatting with a friend next to him (`ChattingWithFriend`)
/// - Other people in the room (`OtherSpeaker(0..3)` / `FriendSpeaking`)
/// - Ambient room noise / silence (`AmbientNoise` / `SilentOrNoise`)
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RoomAcousticTracker {
    pub primary_profile: SpeakerSalienceProfile,
    pub friend_profiles: [Option<SpeakerSalienceProfile>; 4],
    pub noise_floor_q15: u16,
    pub primary_on_axis_amp_q15: u16,
    pub last_primary_ts: u64,
    pub last_other_ts: u64,
    pub last_other_slot: u8,
    pub tts_active_until_ts: u64,
}

impl Default for RoomAcousticTracker {
    fn default() -> Self {
        Self {
            primary_profile: SpeakerSalienceProfile::default(),
            friend_profiles: [None, None, None, None],
            noise_floor_q15: 256,
            primary_on_axis_amp_q15: 4096,
            last_primary_ts: 0,
            last_other_ts: 0,
            last_other_slot: 0,
            tts_active_until_ts: 0,
        }
    }
}

impl RoomAcousticTracker {
    /// Analyze an incoming audio buffer, classify who is speaking (`hue`, `friend_1..4`, `ambient_noise`)
    /// and the room context (`addressing_agent`, `chatting_with_friend`, `friend_speaking`, `silent_or_noise`),
    /// and selectively fold only `PrimaryUser` grains into Hue's `MEM|8` profile (and friend grains into friend slots).
    pub fn classify_and_learn(
        &mut self,
        samples: &[i16],
        sample_rate: u32,
        timestamp_secs: u64,
        transcript_hint: Option<&str>,
    ) -> RoomUtteranceAnalysis {
        let report = extract_salient_grains(samples, sample_rate, 3, timestamp_secs);

        // 0. Check if system TTS is currently playing
        if timestamp_secs < self.tts_active_until_ts {
            return RoomUtteranceAnalysis {
                source: AcousticSourceKind::SystemEcho,
                context: InteractionContext::SilentOrNoise,
                primary_similarity_q15: 0,
                on_axis_ratio_q15: 0,
                should_agent_respond: false,
                salience_report: report,
            };
        }

        // 1. Check if this is non-vocal ambient noise or silence
        let Some(best_grain) = report.top_grains.first() else {
            let mut mean_abs: u64 = 0;
            if !samples.is_empty() {
                for &s in samples {
                    mean_abs += (s as i32).abs() as u64;
                }
                mean_abs /= samples.len() as u64;
            }
            self.noise_floor_q15 =
                (((self.noise_floor_q15 as u64) * 7 + mean_abs) >> 3).min(Q15_ONE as u64) as u16;
            return RoomUtteranceAnalysis {
                source: AcousticSourceKind::AmbientNoise,
                context: InteractionContext::SilentOrNoise,
                primary_similarity_q15: 0,
                on_axis_ratio_q15: 0,
                should_agent_respond: false,
                salience_report: report,
            };
        };

        let grain_avg_env: u32 = best_grain
            .envelope_q15
            .iter()
            .map(|&v| v as u32)
            .sum::<u32>()
            / 16;

        // Reject low-salience / transient noise clicks that barely crossed the floor
        if best_grain.salience_q15 < 512
            || grain_avg_env <= (self.noise_floor_q15 as u32).saturating_add(64)
        {
            return RoomUtteranceAnalysis {
                source: AcousticSourceKind::AmbientNoise,
                context: InteractionContext::SilentOrNoise,
                primary_similarity_q15: 0,
                on_axis_ratio_q15: 0,
                should_agent_respond: false,
                salience_report: report,
            };
        }

        // 2. Compare against Primary User ("Hue") profile
        let primary_sim_q15 = speaker_similarity_q15(&self.primary_profile, &report);

        // Compute on-axis amplitude ratio relative to Hue's normal direct-to-mic speaking level
        let baseline_amp = (self.primary_on_axis_amp_q15 as u32).max(512);
        let on_axis_ratio_q15 = ((grain_avg_env * (Q15_ONE as u32)) / baseline_amp)
            .min(Q15_ONE as u32) as u16;

        // Check if transcript contains an explicit direct-address wake word to the AI
        let has_ai_wake_word = transcript_hint
            .map(|t| {
                let low = t.to_ascii_lowercase();
                low.contains("gemini")
                    || low.contains("alexia")
                    || low.contains("qwave")
                    || low.contains("claude")
                    || low.contains("codex")
                    || low.contains("hey aye")
            })
            .unwrap_or(false);

        // Threshold for matching Primary User ("Hue"): >= 19_000 in Q15 (~58% pitch + cadence match)
        if primary_sim_q15 >= 19_000 || self.primary_profile.grains_learned == 0 {
            // Update Hue's on-axis amplitude baseline when speaking clearly on-axis
            if grain_avg_env > (baseline_amp / 2) {
                self.primary_on_axis_amp_q15 =
                    (((baseline_amp * 3) + grain_avg_env) >> 2).clamp(512, Q15_ONE as u32) as u16;
            }

            // Fold Hue's highest-salience grains into his personal MEM|8 SpeakerSalienceProfile!
            self.primary_profile.absorb_report(&report);
            self.last_primary_ts = timestamp_secs;

            // Determine whether Hue is addressing the AI or chatting with a friend next to him:
            // - If a friend (`OtherSpeaker`) spoke within the last 10 seconds AND Hue didn't use an AI wake word -> `ChattingWithFriend`
            // - Or if Hue is speaking far off-axis (`on_axis_ratio_q15 < 13_000`, ~40% of normal mic energy, turned toward friend) without wake word -> `ChattingWithFriend`
            let friend_spoke_recently = self.last_other_ts > 0
                && timestamp_secs.saturating_sub(self.last_other_ts) <= 10;
            let turned_off_axis = on_axis_ratio_q15 < 13_000;

            let context = if !has_ai_wake_word && (friend_spoke_recently || turned_off_axis) {
                InteractionContext::ChattingWithFriend
            } else {
                InteractionContext::AddressingAgent
            };

            return RoomUtteranceAnalysis {
                source: AcousticSourceKind::PrimaryUser,
                context,
                primary_similarity_q15: primary_sim_q15,
                on_axis_ratio_q15,
                should_agent_respond: context == InteractionContext::AddressingAgent,
                salience_report: report,
            };
        }

        // 3. Another human speaker in the room (`OtherSpeaker(slot)`)!
        // Match against existing friend slots or allocate a new slot (0..=3)
        let mut best_slot = 0usize;
        let mut best_friend_sim = 0u16;
        let mut empty_slot: Option<usize> = None;

        for (idx, slot_opt) in self.friend_profiles.iter().enumerate() {
            if let Some(friend_prof) = slot_opt {
                let sim = speaker_similarity_q15(friend_prof, &report);
                if sim > best_friend_sim {
                    best_friend_sim = sim;
                    best_slot = idx;
                }
            } else if empty_slot.is_none() {
                empty_slot = Some(idx);
            }
        }

        let chosen_slot = if best_friend_sim >= 19_000 {
            best_slot
        } else if let Some(free_idx) = empty_slot {
            free_idx
        } else {
            best_slot
        };

        let mut friend_prof = self.friend_profiles[chosen_slot]
            .take()
            .unwrap_or_default();
        friend_prof.absorb_report(&report);
        self.friend_profiles[chosen_slot] = Some(friend_prof);

        self.last_other_ts = timestamp_secs;
        self.last_other_slot = chosen_slot as u8;

        RoomUtteranceAnalysis {
            source: AcousticSourceKind::OtherSpeaker(chosen_slot as u8),
            context: InteractionContext::FriendSpeaking,
            primary_similarity_q15: primary_sim_q15,
            on_axis_ratio_q15,
            should_agent_respond: has_ai_wake_word,
            salience_report: report,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zero_float_marine_detects_salient_vocal_wave_and_rejects_silence() {
        let sr = 16_000u32;
        let silence = vec![12i16; 1600];
        let rep_silent = extract_salient_grains(&silence, sr, 3, 1700000000);
        assert!(rep_silent.top_grains.is_empty());

        // Construct an integer triangle/harmonic wave at ~160 Hz (period = 100 samples at 16kHz)
        let mut voiced = Vec::with_capacity(3200);
        for i in 0..3200usize {
            let phase = (i % 100) as i32;
            let tri = if phase < 50 {
                (phase - 25) * 600
            } else {
                (75 - phase) * 600
            };
            voiced.push(tri.clamp(-20_000, 20_000) as i16);
        }

        let report = extract_salient_grains(&voiced, sr, 3, 1700000000);
        assert!(!report.top_grains.is_empty());
        let top = &report.top_grains[0];
        assert!(top.salience_q15 > 1000);
        // 16000 / 100 = 160 Hz exact p/q Rational!
        let f0_int = top.f0_hz.num / top.f0_hz.den as i32;
        assert!((150..=170).contains(&f0_int), "f0 was {f0_int} Hz");

        // Verify 79-byte MEM|8 WaveInt round-trip
        let frame = top.wave.to_frame();
        assert_eq!(frame.len(), 79);
        assert_eq!(WaveInt::from_frame(&frame).unwrap(), top.wave);
    }

    #[test]
    fn salient_speech_combiner_modulates_wav_without_floats() {
        let samples: Vec<i16> = (0..2400).map(|i| (((i % 120) as i32 - 60) * 200) as i16).collect();
        let wav = encode_wav_i16(24_000, &samples);
        let report = extract_salient_grains(&samples, 24_000, 2, 1700000000);
        let mut profile = SpeakerSalienceProfile::default();
        profile.absorb_report(&report);
        assert!(profile.grains_learned > 0);

        let modulated = combine_salient_speech_wav(&wav, &profile);
        let (sr, out_samples) = decode_wav_i16(&modulated).unwrap();
        assert_eq!(sr, 24_000);
        assert_eq!(out_samples.len(), samples.len());
    }

    #[test]
    fn room_tracker_distinguishes_primary_user_noise_friend_and_side_chat() {
        let sr = 16_000u32;
        let mut tracker = RoomAcousticTracker::default();

        // 1. Ambient room noise -> AmbientNoise / SilentOrNoise
        let noise = vec![25i16; 3200];
        let r_noise = tracker.classify_and_learn(&noise, sr, 1000, None);
        assert_eq!(r_noise.source, AcousticSourceKind::AmbientNoise);
        assert_eq!(r_noise.context, InteractionContext::SilentOrNoise);
        assert!(!r_noise.should_agent_respond);

        // 2. Primary user ("Hue") speaking on-axis at ~145 Hz (period = 110 samples at 16kHz)
        let hue_voice: Vec<i16> = (0..3200)
            .map(|i| {
                let p = (i % 110) as i32;
                let v = if p < 55 { (p - 27) * 520 } else { (82 - p) * 520 };
                v.clamp(-18_000, 18_000) as i16
            })
            .collect();
        let r_hue = tracker.classify_and_learn(&hue_voice, sr, 1005, Some("Hello Gemini"));
        assert_eq!(r_hue.source, AcousticSourceKind::PrimaryUser);
        assert_eq!(r_hue.context, InteractionContext::AddressingAgent);
        assert!(r_hue.should_agent_respond);

        // 3. Friend next to Hue speaking at ~266 Hz (period = 60 samples at 16kHz)
        let friend_voice: Vec<i16> = (0..3200)
            .map(|i| {
                let p = (i % 60) as i32;
                let v = if p < 30 { (p - 15) * 700 } else { (45 - p) * 700 };
                v.clamp(-15_000, 15_000) as i16
            })
            .collect();
        let r_friend = tracker.classify_and_learn(&friend_voice, sr, 1008, Some("Hey Chris check this out"));
        assert_eq!(r_friend.source, AcousticSourceKind::OtherSpeaker(0));
        assert_eq!(r_friend.context, InteractionContext::FriendSpeaking);
        assert!(!r_friend.should_agent_respond);

        // 4. Hue replies to his friend 3 seconds later (dyadic turn-taking, no AI wake word) -> ChattingWithFriend!
        let r_side = tracker.classify_and_learn(&hue_voice, sr, 1011, Some("Yeah that looks awesome"));
        assert_eq!(r_side.source, AcousticSourceKind::PrimaryUser);
        assert_eq!(r_side.context, InteractionContext::ChattingWithFriend);
        assert!(!r_side.should_agent_respond);

        // 5. Hue addresses Gemini directly during the conversation ("Hey Gemini what do you think?") -> AddressingAgent!
        let r_wake = tracker.classify_and_learn(&hue_voice, sr, 1014, Some("Hey Gemini what do you think?"));
        assert_eq!(r_wake.source, AcousticSourceKind::PrimaryUser);
        assert_eq!(r_wake.context, InteractionContext::AddressingAgent);
        assert!(r_wake.should_agent_respond);
    }
}
