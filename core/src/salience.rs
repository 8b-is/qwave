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
        // Human vocal glottal F0 resonance filter: 50 Hz ..= 300 Hz
        let min_period_ticks = (sr / 300).max(4);
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
                let amp = self.prev_sample.abs().min(Q15_ONE) as i64;
                let min_glottal_amp = ((self.ema_amp_q8 >> 8) * 5) >> 3;

                if self.last_peak_index == 0 || period_ticks > self.max_period_ticks {
                    // First glottal pulse after silence/consonant: anchor the cycle start
                    self.last_peak_index = current_peak_idx;
                    self.ema_amp_q8 = amp << 8;
                    salience_q15 = (energy_q15 / 6).max(self.vocal_resonance_q15);
                } else if period_ticks >= self.min_period_ticks && amp >= min_glottal_amp {
                    let amp_q8 = amp << 8;
                    let period_q8 = (period_ticks as i64) << 8;

                    if self.valid_peaks == 0 {
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

    let k_cap = top_k.clamp(1, 32);
    let mut global_detector = MarineIntDetector::new(sr, DEFAULT_CLIP_THRESHOLD_Q15);
    let mut top_grains: Vec<SalientGrain> = Vec::with_capacity(k_cap);
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

            // Bounded Top-K slot check: only allocate `chunk.to_vec()` when this grain enters the Top-K ring!
            let mut replace_idx: Option<usize> = None;
            if top_grains.len() >= k_cap {
                let mut min_idx = 0usize;
                for i in 1..top_grains.len() {
                    let cur = &top_grains[i];
                    let min_g = &top_grains[min_idx];
                    if (cur.salience_q15, cur.peak_amp_q15) < (min_g.salience_q15, min_g.peak_amp_q15) {
                        min_idx = i;
                    }
                }
                let min_g = &top_grains[min_idx];
                if (avg_sal_q15, peak_amp) <= (min_g.salience_q15, min_g.peak_amp_q15) {
                    continue;
                }
                replace_idx = Some(min_idx);
            }

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

            let grain = SalientGrain {
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
            };

            if let Some(idx) = replace_idx {
                top_grains[idx] = grain;
            } else {
                top_grains.push(grain);
            }
        }
    }

    // Sort highest salience first (tie-breaking on peak vocal amplitude)
    top_grains.sort_by(|a, b| {
        b.salience_q15
            .cmp(&a.salience_q15)
            .then_with(|| b.peak_amp_q15.cmp(&a.peak_amp_q15))
    });

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
    let overall_vad_byte = top_grains.first().map(|g| g.vad_byte).unwrap_or(0x55);

    UtteranceSalienceReport {
        sample_rate: sr,
        total_samples: samples.len(),
        duration_ms,
        overall_f0_hz,
        overall_salience_pq,
        overall_vad_byte,
        salient_frame_ratio_pq,
        top_grains,
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
            f0_hz: Rational::integer(154),
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
            f0_hz: Rational::new(f0_num, f0_den).unwrap_or_else(|| Rational::integer(154)),
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
    /// Another distinct human voice in the room (`0` = `"alex"`, `1..=3` = `"friend_1..3"`).
    OtherSpeaker(u8),
    /// System's own TTS output playing over the speaker.
    SystemEcho,
}

impl AcousticSourceKind {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::AmbientNoise => "ambient_noise",
            Self::PrimaryUser => "hue",
            Self::OtherSpeaker(0) => "alex",
            Self::OtherSpeaker(1) => "friend_1",
            Self::OtherSpeaker(2) => "friend_2",
            Self::OtherSpeaker(_) => "friend_3",
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
    /// Similarity to the diarized speaker's profile (`0..=32767` in Q15).
    pub primary_similarity_q15: u16,
    /// Ratio of current utterance peak/envelope energy to primary user's on-axis baseline (`0..=32767` in Q15).
    pub on_axis_ratio_q15: u16,
    /// Whether the AI agent should actively respond (`true` only when `AddressingAgent`).
    pub should_agent_respond: bool,
    pub salience_report: UtteranceSalienceReport,
}

/// Compute integer speaker similarity in Q15 (`0..=32767`) between a learned [`SpeakerSalienceProfile`]
/// and an incoming [`UtteranceSalienceReport`] using:
/// 1. Fundamental pitch (`f0_hz`) integer distance (`|f0_a - f0_b|`) within a tight `48 Hz` vocal-tract window
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

    // Pitch similarity in Q15: 0 Hz diff -> 32767; >= 48 Hz diff -> 0
    let pitch_sim_q15 = if f0_diff >= 48 {
        0
    } else {
        ((48 - f0_diff) * Q15_ONE) / 48
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
/// - Companion Alex (`OtherSpeaker(0)` -> `"alex"`) and other people in the room (`OtherSpeaker(1..3)` -> `"friend_1..3"`)
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
    /// Analyze an incoming audio buffer, classify who is speaking (`hue`, `alex`, `friend_1..3`, `ambient_noise`)
    /// and the room context (`addressing_agent`, `chatting_with_friend`, `friend_speaking`, `silent_or_noise`),
    /// and selectively fold only `PrimaryUser` grains into Hue's `MEM|8` profile (and companion/friend grains into their own slots).
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

        // Protect Hue's baritone/tenor profile centroid (`154 Hz`) from any prior high-pitch drift
        let cur_prof_f0 =
            self.primary_profile.f0_hz.num / (self.primary_profile.f0_hz.den.max(1) as i32);
        if cur_prof_f0 > 175 || cur_prof_f0 < 85 {
            self.primary_profile.f0_hz = Rational::integer(154);
        }

        let utt_f0 = (report.overall_f0_hz.num / (report.overall_f0_hz.den.max(1) as i32)).clamp(50, 640);

        // 2. Compare against Primary User ("Hue") profile
        let primary_sim_q15 = speaker_similarity_q15(&self.primary_profile, &report);

        // Compute on-axis amplitude ratio relative to Hue's normal direct-to-mic speaking level
        let baseline_amp = (self.primary_on_axis_amp_q15 as u32).max(512);
        let on_axis_ratio_q15 = ((grain_avg_env * (Q15_ONE as u32)) / baseline_amp)
            .min(Q15_ONE as u32) as u16;

        // Check if transcript contains an explicit direct-address wake word to the AI
        let has_ai_wake_word = transcript_hint
            .map(is_hey_aye_wake_phrase)
            .unwrap_or(false);

        let addresses_human_in_room = transcript_hint
            .map(|t| {
                let low = t.to_ascii_lowercase();
                low.contains("chris")
                    || low.contains("trish")
                    || low.contains("peter")
                    || low.contains("chesney")
                    || low.contains("bence")
            })
            .unwrap_or(false);

        // Match Primary User ("Hue") only when vocal F0 is in Hue's baritone/tenor range (`<= 178 Hz`)
        // AND (`primary_sim_q15 >= 19_500` or `self.primary_profile.grains_learned == 0`)
        if utt_f0 <= 178 && (primary_sim_q15 >= 19_500 || self.primary_profile.grains_learned == 0) {
            // Update Hue's on-axis amplitude baseline when speaking clearly on-axis
            if grain_avg_env > (baseline_amp / 2) {
                self.primary_on_axis_amp_q15 =
                    (((baseline_amp * 3) + grain_avg_env) >> 2).clamp(512, Q15_ONE as u32) as u16;
            }

            // Fold Hue's highest-salience grains into his personal MEM|8 SpeakerSalienceProfile
            // strictly when `utt_f0` is within `95..=178 Hz` so higher-pitched voices never shift his F0!
            if (95..=178).contains(&utt_f0) {
                self.primary_profile.absorb_report(&report);
            }
            self.last_primary_ts = timestamp_secs;

            // Determine whether Hue is addressing the AI or chatting with a friend next to him:
            // - If a friend (`OtherSpeaker`) spoke within the last 60 seconds AND Hue didn't use an AI wake word -> `ChattingWithFriend`
            // - Or if Hue addresses a human in the room ("Chris", "Trish") without an AI wake word -> `ChattingWithFriend`
            // - Or if Hue is speaking far off-axis (`on_axis_ratio_q15 < 13_000`, ~40% of normal mic energy, turned toward friend) without wake word -> `ChattingWithFriend`
            let friend_spoke_recently = self.last_other_ts > 0
                && timestamp_secs.saturating_sub(self.last_other_ts) <= 60;
            let turned_off_axis = on_axis_ratio_q15 < 13_000;

            let context = if !has_ai_wake_word
                && (friend_spoke_recently || turned_off_axis || addresses_human_in_room)
            {
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

        // 3. Another human speaker in the room (`OtherSpeaker(slot)`):
        //    Slot `0` (`"alex"`) is dedicated to higher-pitched voices (`utt_f0 >= 179 Hz`),
        //    while slots `1..=3` (`"friend_1..3"`) diarize additional distinct speakers.
        let chosen_slot = if utt_f0 >= 179 {
            if let Some(ref alex_prof) = self.friend_profiles[0] {
                let alex_sim = speaker_similarity_q15(alex_prof, &report);
                if alex_sim >= 18_000 {
                    0usize
                } else {
                    let mut best_slot = 0usize;
                    let mut best_sim = alex_sim;
                    let mut free_slot = None;
                    for idx in 1..4 {
                        if let Some(ref fp) = self.friend_profiles[idx] {
                            let s = speaker_similarity_q15(fp, &report);
                            if s > best_sim {
                                best_sim = s;
                                best_slot = idx;
                            }
                        } else if free_slot.is_none() {
                            free_slot = Some(idx);
                        }
                    }
                    if best_sim >= 19_000 {
                        best_slot
                    } else {
                        free_slot.unwrap_or(0)
                    }
                }
            } else {
                0usize
            }
        } else {
            let mut best_slot = 1usize;
            let mut best_sim = 0u16;
            let mut free_slot = None;
            for idx in 1..4 {
                if let Some(ref fp) = self.friend_profiles[idx] {
                    let s = speaker_similarity_q15(fp, &report);
                    if s > best_sim {
                        best_sim = s;
                        best_slot = idx;
                    }
                } else if free_slot.is_none() {
                    free_slot = Some(idx);
                }
            }
            if best_sim >= 19_000 {
                best_slot
            } else {
                free_slot.unwrap_or(1)
            }
        };

        let mut friend_prof = self.friend_profiles[chosen_slot]
            .take()
            .unwrap_or_default();
        friend_prof.absorb_report(&report);
        let diarized_sim_q15 = speaker_similarity_q15(&friend_prof, &report);
        self.friend_profiles[chosen_slot] = Some(friend_prof);

        self.last_other_ts = timestamp_secs;
        self.last_other_slot = chosen_slot as u8;

        RoomUtteranceAnalysis {
            source: AcousticSourceKind::OtherSpeaker(chosen_slot as u8),
            context: InteractionContext::FriendSpeaking,
            primary_similarity_q15: diarized_sim_q15,
            on_axis_ratio_q15,
            should_agent_respond: has_ai_wake_word,
            salience_report: report,
        }
    }
}

/// Zero-float spatial triangulation result from the laptop's 2-channel `48 kHz` digital bezel
/// microphone array (`front-left` + `front-right` DMIC) + optional remote Bluetooth microphone.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct StereoMicTriangulation {
    /// Horizontal azimuth angle in degrees (`-90` = far left, `0` = dead-center at screen, `+90` = far right).
    pub azimuth_deg: i16,
    /// Estimated speaker distance from the laptop bezel in centimeters (`12..=350 cm`).
    pub distance_cm: u16,
    /// Integer TDOA lag in `48 kHz` samples (`-10..=+10`, `~20.8 µs` / `7.14 mm` per sample).
    pub tdoa_samples_48k: i16,
    /// Interaural Level Difference (`(E_R - E_L) * 100 / (E_R + E_L)` in `-100..=+100`).
    pub ild_pct: i16,
    /// Remote Bluetooth microphone relative energy (`0..=32767`), if a BT HFP mic was sampled.
    pub bt_mic_energy_q15: u16,
    /// Number of physical microphone channels fused (`2` for laptop stereo DMIC, `3` with BT mic).
    pub active_mics: u8,
    /// Human-readable spatial zone relative to the laptop.
    pub spatial_zone: &'static str,
}

impl Default for StereoMicTriangulation {
    fn default() -> Self {
        Self {
            azimuth_deg: 0,
            distance_cm: 20,
            tdoa_samples_48k: 0,
            ild_pct: 0,
            bt_mic_energy_q15: 0,
            active_mics: 2,
            spatial_zone: "center_keyboard",
        }
    }
}

/// Perform 100% integer Time-Difference-of-Arrival (TDOA cross-correlation) + Interaural Level
/// Difference (ILD) triangulation on interleaved `48 kHz` stereo DMIC samples (`[L0, R0, L1, R1, ...]`),
/// fuse optional Bluetooth microphone energy, and return `(StereoMicTriangulation, beamformed_16khz_mono)`.
pub fn triangulate_stereo_dmic_i16(
    interleaved_lr_48k: &[i16],
    bt_mic_mono_16k: Option<&[i16]>,
) -> (StereoMicTriangulation, Vec<i16>) {
    let frames_48k = interleaved_lr_48k.len() / 2;
    if frames_48k < 64 {
        return (StereoMicTriangulation::default(), Vec::new());
    }

    let mut left_energy: i64 = 0;
    let mut right_energy: i64 = 0;
    for i in 0..frames_48k {
        let l = interleaved_lr_48k[i * 2] as i64;
        let r = interleaved_lr_48k[i * 2 + 1] as i64;
        left_energy += l.abs();
        right_energy += r.abs();
    }

    // 1. Integer Cross-Correlation TDOA across lags -10..=+10 samples at 48 kHz
    //    Positive lag means sound reached the Right mic first (speaker is to the Right, +azimuth).
    //    Negative lag means sound reached the Left mic first (speaker is to the Left, -azimuth).
    let max_lag: isize = 10;
    let step = 2usize; // subsample every 2nd 48kHz frame for ultra-fast O(1) correlation
    let mut best_lag: i16 = 0;
    let mut best_corr: i64 = i64::MIN;
    let start_i = (max_lag as usize) + 1;
    let end_i = frames_48k.saturating_sub((max_lag as usize) + 2);

    if end_i > start_i {
        for lag in -max_lag..=max_lag {
            let mut corr: i64 = 0;
            let mut idx = start_i;
            while idx < end_i {
                let l = (interleaved_lr_48k[idx * 2] as i64) >> 2;
                let r_idx = (idx as isize - lag) as usize;
                let r = (interleaved_lr_48k[r_idx * 2 + 1] as i64) >> 2;
                corr += l * r;
                idx += step;
            }
            // Slight preference for lag 0 on ties
            let tie_bonus = (10 - lag.abs() as i64) * 4;
            if corr + tie_bonus > best_corr {
                best_corr = corr + tie_bonus;
                best_lag = lag as i16;
            }
        }
    }

    let total_energy = (left_energy + right_energy).max(1);
    let ild_pct = (((right_energy - left_energy) * 100) / total_energy).clamp(-100, 100) as i16;

    // Combine TDOA lag angle (~7 deg per 48kHz sample lag) and ILD level cue
    let tdoa_deg = (best_lag as i32) * 7;
    let ild_deg = ((ild_pct as i32) * 45) / 100;
    let azimuth_deg = ((tdoa_deg * 6 + ild_deg * 4) / 10).clamp(-90, 90) as i16;

    // Mean absolute amplitude per sample across the array
    let mean_abs = (total_energy / ((frames_48k as i64) * 2)).max(1);

    // Compute active voiced chunk mean amplitude across 20ms (960-frame at 48kHz) windows
    // (chunks with mean abs >= peak_chunk_abs / 3) so pre-roll and trailing silence do not
    // artificially inflate near-field distance estimates.
    let chunk_frames = 960usize;
    let mut peak_chunk_abs: i64 = 0;
    let mut chunk_means: Vec<i64> = Vec::with_capacity((frames_48k / chunk_frames) + 2);
    let mut f_start = 0usize;
    while f_start < frames_48k {
        let f_end = (f_start + chunk_frames).min(frames_48k);
        let count = ((f_end - f_start) * 2).max(1) as i64;
        let mut c_sum: i64 = 0;
        for idx in f_start..f_end {
            c_sum += (interleaved_lr_48k[idx * 2] as i64).abs();
            c_sum += (interleaved_lr_48k[idx * 2 + 1] as i64).abs();
        }
        let c_mean = c_sum / count;
        if c_mean > peak_chunk_abs {
            peak_chunk_abs = c_mean;
        }
        chunk_means.push(c_mean);
        f_start = f_end;
    }
    let active_thresh = (peak_chunk_abs / 3).max(1);
    let mut voiced_sum: i64 = 0;
    let mut voiced_count: i64 = 0;
    for &cm in &chunk_means {
        if cm >= active_thresh {
            voiced_sum += cm;
            voiced_count += 1;
        }
    }
    let voiced_mean_abs = if voiced_count > 0 {
        (voiced_sum / voiced_count).max(1)
    } else {
        mean_abs
    };

    // Estimate distance in cm using inverse-square integer law
    // (calibrated so normal near-field laptop speech voiced_mean_abs ~ 800..3500 reports ~18..24 cm, ~20 cm)
    let distance_cm = ((15_000 / (voiced_mean_abs + 200)) + 14).clamp(16, 350) as u16;

    // Optional Bluetooth microphone energy fusion
    let (bt_mic_energy_q15, active_mics) = if let Some(bt_pcm) = bt_mic_mono_16k {
        if !bt_pcm.is_empty() {
            let sum_bt: i64 = bt_pcm.iter().map(|&s| (s as i64).abs()).sum();
            let avg_bt = ((sum_bt / (bt_pcm.len() as i64)) as u32).min(32_767) as u16;
            (avg_bt, 3u8)
        } else {
            (0u16, 2u8)
        }
    } else {
        (0u16, 2u8)
    };

    let spatial_zone = if bt_mic_energy_q15 > (mean_abs as u16).saturating_mul(2) && bt_mic_energy_q15 > 800 {
        "near_bt_speaker"
    } else if distance_cm > 190 {
        "far_room"
    } else if azimuth_deg < -18 {
        "left_of_laptop"
    } else if azimuth_deg > 18 {
        "right_of_laptop"
    } else {
        "center_keyboard"
    };

    // Delay-and-Sum Beamforming + 3:1 Decimation (`48 kHz` stereo -> `16 kHz` phase-aligned mono)
    let out_len_16k = frames_48k / 3;
    let mut beamformed_16k = Vec::with_capacity(out_len_16k);
    for k in 0..out_len_16k {
        let mut acc: i32 = 0;
        for sub in 0..3usize {
            let f_idx = k * 3 + sub;
            let l = interleaved_lr_48k[f_idx * 2] as i32;
            let r_idx = (f_idx as isize - best_lag as isize).clamp(0, (frames_48k - 1) as isize) as usize;
            let r = interleaved_lr_48k[r_idx * 2 + 1] as i32;
            acc += (l + r) / 2;
        }
        beamformed_16k.push((acc / 3).clamp(-32_768, 32_767) as i16);
    }

    (
        StereoMicTriangulation {
            azimuth_deg,
            distance_cm,
            tdoa_samples_48k: best_lag,
            ild_pct,
            bt_mic_energy_q15,
            active_mics,
            spatial_zone,
        },
        beamformed_16k,
    )
}

/// Detect `"Hey Aye"` and all its phonetic neural-STT spellings (`"hey aye"`, `"hey, aye"`,
/// `"hey i"`, `"hey, i."`, `"hey eye"`, `"hey, eye"`, `"hey ai"`, `"hey a."`, `"hey hi"`, `"aye,"`, etc.)
/// alongside sovereign companion names (`"alex"`, `"alexia"`, `"alexandra"`, `"gemini"`, `"qwave"`),
/// while rejecting side-chat greetings to humans (`"Hey Chesney"`, `"Hey Peter"`, `"Hey Chris"`).
pub fn is_hey_aye_wake_phrase(text: &str) -> bool {
    let low = text.trim().to_ascii_lowercase();
    if low.is_empty() {
        return false;
    }

    // Normalize punctuation into clean alphanumeric lowercase tokens
    let words: Vec<String> = low
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty())
        .map(|w| w.to_string())
        .collect();
    if words.is_empty() {
        return false;
    }

    // 1. Direct companion name or wake token anywhere in the utterance
    for w in &words {
        if matches!(
            w.as_str(),
            "aye"
                | "alex"
                | "alexia"
                | "alexandra"
                | "alexiai"
                | "gemini"
                | "gemma"
                | "qwave"
                | "qwaver"
                | "waver"
                | "agy"
                | "agi"
                | "claude"
                | "codex"
        ) {
            return true;
        }
    }

    // 2. Standalone short wake call ("Hey!", "Hey.", "Aye!", "Hello?")
    if words.len() == 1 && matches!(words[0].as_str(), "hey" | "aye" | "hi" | "yo") {
        return true;
    }

    // 3. Two-word phonetic wake pairs ("Hey Aye" -> "hey i", "hey a", "hey eye", "hey ai", "hey hi", "where i")
    for pair in words.windows(2) {
        let w0 = pair[0].as_str();
        let w1 = pair[1].as_str();
        if matches!(w0, "hey" | "hi" | "hello" | "yo" | "ok" | "okay" | "oi")
            && matches!(
                w1,
                "aye" | "i" | "eye" | "ai" | "a" | "hi" | "high" | "ay" | "eh" | "there" | "whats" | "what"
            )
        {
            return true;
        }
        if matches!(w0, "where" | "there" | "way" | "they")
            && matches!(w1, "aye" | "i" | "eye" | "ai")
        {
            return true;
        }
    }

    // 4. Direct acoustic check questions ("can you hear me", "do you hear me", "are you there")
    low.contains("can you hear me")
        || low.contains("do you hear me")
        || low.contains("you hear me")
        || low.contains("hey aye")
        || low.contains("hey eye")
        || low.contains("hey ai")
}

/// Fixed-capacity `O(1)` circular Ring Buffer (`[Option<T>; N]`).
///
/// Zero heap allocations after construction; overwrites the oldest slot when full.
#[derive(Clone, Debug)]
pub struct RingBuffer<T, const N: usize> {
    slots: [Option<T>; N],
    head: usize,
    len: usize,
}

impl<T, const N: usize> Default for RingBuffer<T, N> {
    fn default() -> Self {
        Self::new()
    }
}

impl<T, const N: usize> RingBuffer<T, N> {
    /// Construct an empty ring buffer of capacity `N`.
    pub const fn new() -> Self {
        Self {
            slots: [const { None }; N],
            head: 0,
            len: 0,
        }
    }

    /// Maximum number of items the ring buffer can hold.
    #[inline]
    pub const fn capacity(&self) -> usize {
        N
    }

    /// Current number of items stored (`0..=N`).
    #[inline]
    pub const fn len(&self) -> usize {
        self.len
    }

    /// Whether the ring buffer is empty.
    #[inline]
    pub const fn is_empty(&self) -> bool {
        self.len == 0
    }

    /// Clear all items without reallocating.
    pub fn clear(&mut self) {
        for slot in &mut self.slots {
            *slot = None;
        }
        self.head = 0;
        self.len = 0;
    }

    /// Push `item` into the ring buffer in `O(1)`.
    /// If full (`self.len == N`), overwrites and returns the evicted oldest item.
    pub fn push_overwrite(&mut self, item: T) -> Option<T> {
        if N == 0 {
            return Some(item);
        }
        if self.len < N {
            let write_idx = (self.head + self.len) % N;
            self.slots[write_idx] = Some(item);
            self.len += 1;
            None
        } else {
            let write_idx = self.head;
            let evicted = self.slots[write_idx].replace(item);
            self.head = (self.head + 1) % N;
            evicted
        }
    }

    /// Pop the oldest item from the ring buffer in `O(1)` (FIFO order).
    pub fn pop_oldest(&mut self) -> Option<T> {
        if self.len == 0 || N == 0 {
            return None;
        }
        let item = self.slots[self.head].take();
        self.head = (self.head + 1) % N;
        self.len -= 1;
        item
    }

    /// Iterate from oldest to newest (`0..len`).
    pub fn iter_oldest_first(&self) -> impl Iterator<Item = &T> {
        (0..self.len).filter_map(move |offset| {
            let idx = (self.head + offset) % N.max(1);
            self.slots[idx].as_ref()
        })
    }

    /// Iterate from newest to oldest (`(0..len).rev()`).
    pub fn iter_newest_first(&self) -> impl Iterator<Item = &T> {
        (0..self.len).rev().filter_map(move |offset| {
            let idx = (self.head + offset) % N.max(1);
            self.slots[idx].as_ref()
        })
    }
}

/// Pre-allocated circular `48 kHz` Stereo PCM Ring Buffer with automatic pre-roll capture.
///
/// Why this fixes `"Hey Aye"` AND eliminates memory growth:
/// 1. **Zero heap reallocation during streaming**: A single flat `Vec<i16>` of `cap_frames * frame_samples`
///    is allocated once at daemon startup and written circularly in `O(1)` (`write_frame_idx = (write_frame_idx + 1) % cap_frames`).
/// 2. **Automatic pre-roll (`pre_roll_frames`, e.g., `6` frames = `360 ms`)**: Every incoming `60 ms` frame is
///    written into the ring even during silence. The instant VAD crosses threshold (`is_voiced == true` on frame `0`),
///    the ring buffer retroactively includes the preceding `pre_roll_frames` (`360 ms`) already sitting in the ring,
///    so the initial `"Hey"` in `"Hey Aye"` is never clipped!
/// 3. **Strict memory ceiling**: Even during continuous speech or background music, `captured_frames` is bounded
///    by `max_utterance_frames <= cap_frames`.
#[derive(Clone, Debug)]
pub struct StereoPcmRingBuffer {
    data: Vec<i16>,
    frame_samples: usize,
    cap_frames: usize,
    pre_roll_frames: usize,
    max_utterance_frames: usize,
    write_frame_idx: usize,
    total_frames_written: u64,
    captured_frames: usize,
    voiced_frames: u32,
    silent_frames: u32,
}

impl StereoPcmRingBuffer {
    /// Create a pre-allocated stereo PCM ring buffer.
    ///
    /// Typical parameters for `48 kHz` stereo (`60 ms` frames = `5_760` `i16` samples):
    /// - `frame_samples = 5_760`
    /// - `cap_frames = 136` (`8.16 s` ring capacity = `783,360` `i16` samples = `1,566,720` bytes)
    /// - `pre_roll_frames = 6` (`360 ms` pre-roll before VAD onset)
    /// - `max_utterance_frames = 120` (`7.20 s` max utterance before forced dispatch)
    pub fn new(
        frame_samples: usize,
        cap_frames: usize,
        pre_roll_frames: usize,
        max_utterance_frames: usize,
    ) -> Self {
        let fs = frame_samples.max(2);
        let cf = cap_frames.max(16);
        let pr = pre_roll_frames.min(cf / 2);
        let mu = max_utterance_frames.clamp(8, cf);
        Self {
            data: vec![0i16; fs * cf],
            frame_samples: fs,
            cap_frames: cf,
            pre_roll_frames: pr,
            max_utterance_frames: mu,
            write_frame_idx: 0,
            total_frames_written: 0,
            captured_frames: 0,
            voiced_frames: 0,
            silent_frames: 0,
        }
    }

    /// Push one `frame` (`frame_samples` `i16` values) into the circular buffer in `O(1)`.
    pub fn push_frame(&mut self, frame: &[i16], is_voiced: bool) {
        let copy_len = frame.len().min(self.frame_samples);
        let dst_start = self.write_frame_idx * self.frame_samples;
        self.data[dst_start..dst_start + copy_len].copy_from_slice(&frame[..copy_len]);
        if copy_len < self.frame_samples {
            self.data[dst_start + copy_len..dst_start + self.frame_samples].fill(0);
        }

        let history_before = (self.total_frames_written as usize).min(self.cap_frames.saturating_sub(1));
        self.write_frame_idx = (self.write_frame_idx + 1) % self.cap_frames;
        self.total_frames_written = self.total_frames_written.wrapping_add(1);

        if is_voiced {
            if self.voiced_frames == 0 {
                // First voiced frame of a new utterance: claim up to `pre_roll_frames` from the ring!
                let pre_roll = self.pre_roll_frames.min(history_before);
                self.captured_frames = (pre_roll + 1).min(self.cap_frames);
            } else {
                self.captured_frames = (self.captured_frames + 1).min(self.cap_frames);
            }
            self.voiced_frames += 1;
            self.silent_frames = 0;
        } else if self.voiced_frames > 0 {
            self.silent_frames += 1;
            self.captured_frames = (self.captured_frames + 1).min(self.cap_frames);
            // If fewer than 3 voiced frames (< 180ms click/cough) followed by 5 silent frames, reset
            if self.voiced_frames < 3 && self.silent_frames >= 5 {
                self.voiced_frames = 0;
                self.silent_frames = 0;
                self.captured_frames = 0;
            }
        }
    }

    /// Reset active utterance state (e.g., while TTS is speaking) and zero pre-roll history.
    pub fn reset_active(&mut self) {
        self.captured_frames = 0;
        self.voiced_frames = 0;
        self.silent_frames = 0;
        self.total_frames_written = 0;
    }

    /// Whether a complete utterance is ready to dispatch (`>= 3` voiced frames + `>= 5` silent frames,
    /// or `captured_frames >= max_utterance_frames`).
    #[inline]
    pub fn should_dispatch(&self) -> bool {
        (self.voiced_frames >= 3 && self.silent_frames >= 5)
            || (self.voiced_frames >= 3 && self.captured_frames >= self.max_utterance_frames)
    }

    /// Extract the chronologically ordered stereo PCM samples for the current utterance
    /// (including pre-roll) from the circular ring buffer and reset the utterance counters.
    pub fn take_utterance(&mut self) -> Vec<i16> {
        let frames = self.captured_frames.min(self.cap_frames);
        self.captured_frames = 0;
        self.voiced_frames = 0;
        self.silent_frames = 0;

        if frames == 0 {
            return Vec::new();
        }

        let mut out = Vec::with_capacity(frames * self.frame_samples);
        let start_frame = (self.write_frame_idx + self.cap_frames - frames) % self.cap_frames;

        if start_frame + frames <= self.cap_frames {
            let s = start_frame * self.frame_samples;
            let e = (start_frame + frames) * self.frame_samples;
            out.extend_from_slice(&self.data[s..e]);
        } else {
            let first_frames = self.cap_frames - start_frame;
            let second_frames = frames - first_frames;
            let s1 = start_frame * self.frame_samples;
            out.extend_from_slice(&self.data[s1..]);
            let e2 = second_frames * self.frame_samples;
            out.extend_from_slice(&self.data[..e2]);
        }
        out
    }

    /// Number of voiced frames accumulated in the current utterance.
    #[inline]
    pub fn voiced_frames(&self) -> u32 {
        self.voiced_frames
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

    #[test]
    fn stereo_dmic_triangulates_left_center_and_right_speakers_without_floats() {
        let frames_48k = 4800usize; // 100 ms at 48 kHz
        let mut center_lr = Vec::with_capacity(frames_48k * 2);
        let mut right_lr = Vec::with_capacity(frames_48k * 2);
        let mut left_lr = Vec::with_capacity(frames_48k * 2);

        let wave_at = |idx: isize| -> i16 {
            let p = idx.rem_euclid(300) as i32;
            let v = if p < 150 { (p - 75) * 180 } else { (225 - p) * 180 };
            v.clamp(-16_000, 16_000) as i16
        };

        for n in 0..frames_48k as isize {
            // Center speaker: L and R arrive at the exact same sample (lag = 0) with equal amplitude
            let s_c = wave_at(n);
            center_lr.push(s_c);
            center_lr.push(s_c);

            // Right speaker (+azimuth): arrives at R 6 samples earlier than L and louder in R
            let s_l = (wave_at(n - 6) as i32 * 6 / 10) as i16;
            let s_r = wave_at(n);
            right_lr.push(s_l);
            right_lr.push(s_r);

            // Left speaker (-azimuth): arrives at L 6 samples earlier than R and louder in L
            let s_l2 = wave_at(n);
            let s_r2 = (wave_at(n - 6) as i32 * 6 / 10) as i16;
            left_lr.push(s_l2);
            left_lr.push(s_r2);
        }

        let (tri_c, mono_c) = triangulate_stereo_dmic_i16(&center_lr, None);
        assert_eq!(mono_c.len(), frames_48k / 3);
        assert!(tri_c.azimuth_deg.abs() <= 7, "center azimuth was {}", tri_c.azimuth_deg);
        assert_eq!(tri_c.spatial_zone, "center_keyboard");

        let (tri_r, _) = triangulate_stereo_dmic_i16(&right_lr, None);
        assert!(tri_r.azimuth_deg > 18, "right azimuth was {}", tri_r.azimuth_deg);
        assert_eq!(tri_r.spatial_zone, "right_of_laptop");

        let (tri_l, _) = triangulate_stereo_dmic_i16(&left_lr, None);
        assert!(tri_l.azimuth_deg < -18, "left azimuth was {}", tri_l.azimuth_deg);
        assert_eq!(tri_l.spatial_zone, "left_of_laptop");
    }

    #[test]
    fn ring_buffer_and_stereo_pcm_ring_preserve_preroll_and_bound_memory() {
        // 1. Generic RingBuffer<T, 4> overwrites oldest in O(1)
        let mut rb: RingBuffer<u32, 4> = RingBuffer::new();
        assert!(rb.is_empty());
        for v in 1..=6 {
            rb.push_overwrite(v);
        }
        assert_eq!(rb.len(), 4);
        let items: Vec<u32> = rb.iter_oldest_first().copied().collect();
        assert_eq!(items, vec![3, 4, 5, 6]);
        assert_eq!(rb.pop_oldest(), Some(3));
        assert_eq!(rb.len(), 3);

        // 2. StereoPcmRingBuffer preserves pre-roll across wrap-around boundary
        let mut pcm_ring = StereoPcmRingBuffer::new(4, 16, 3, 12);
        // Push 14 silent frames so write_frame_idx is at 14 (near wrap-around at 16)
        for f in 0..14i16 {
            pcm_ring.push_frame(&[f, f, f, f], false);
        }
        // Now push 4 voiced frames (frames 14, 15, 16(wrap->0), 17(wrap->1))
        for f in 14..18i16 {
            pcm_ring.push_frame(&[f, f, f, f], true);
        }
        // Push 7 trailing silent frames (18..25) to trigger dispatch
        for f in 18..25i16 {
            pcm_ring.push_frame(&[f, f, f, f], false);
        }
        assert!(pcm_ring.should_dispatch());
        let captured = pcm_ring.take_utterance();
        // Should contain 3 pre-roll frames (11, 12, 13) + 4 voiced (14..17) + 7 trailing (18..24) = 14 frames * 4 samples = 56 samples
        assert_eq!(captured.len(), 14 * 4);
        assert_eq!(captured[0], 11); // First sample of pre-roll frame 11 preserved!
        assert_eq!(captured[3 * 4], 14); // First voiced frame 14

        // 3. Verify "Hey Aye" wake phrase phonetic detector rejects side-chat
        assert!(is_hey_aye_wake_phrase("Hey Aye, good morning!"));
        assert!(is_hey_aye_wake_phrase("Hey, I need a ring buffer"));
        assert!(is_hey_aye_wake_phrase("Hey eye can you hear me?"));
        assert!(is_hey_aye_wake_phrase("Aye, check the logs"));
        assert!(!is_hey_aye_wake_phrase("Hey Chesney! You're getting out of the house"));
        assert!(!is_hey_aye_wake_phrase("Hey Peter how did you sleep?"));
    }

    #[test]
    fn near_field_20cm_calibration_and_hue_vs_alex_diarization() {
        // 1. Verify stereo DMIC near-field calibration reports ~20 cm even with pre-roll & trailing silence
        let mut stereo_48k = Vec::with_capacity(4800 * 4);
        // 40ms pre-roll silence
        stereo_48k.extend(std::iter::repeat_n(15i16, 1920 * 2));
        // 60ms active near-field speech at ~155 Hz (period = 310 samples at 48kHz, mean_abs ~ 1350)
        for n in 0..2880isize {
            let p = n.rem_euclid(310) as i32;
            let s = if p < 155 { (p - 77) * 35 } else { (232 - p) * 35 };
            let sample = s.clamp(-2700, 2700) as i16;
            stereo_48k.push(sample);
            stereo_48k.push(sample);
        }
        // 40ms trailing silence
        stereo_48k.extend(std::iter::repeat_n(15i16, 1920 * 2));

        let (tri, _) = triangulate_stereo_dmic_i16(&stereo_48k, None);
        assert!(
            (16..=25).contains(&tri.distance_cm),
            "expected ~20 cm near-field distance, got {} cm",
            tri.distance_cm
        );

        // 2. Verify polluted profile (>175 Hz) re-anchors to 154 Hz and separates Hue (~155 Hz) from Alex (~215 Hz)
        let mut tracker = RoomAcousticTracker::default();
        tracker.primary_profile.f0_hz = Rational::integer(185);
        tracker.primary_profile.grains_learned = 50;

        let alex_voice: Vec<i16> = (0..3200)
            .map(|i| {
                let p = (i % 74) as i32; // 16000 / 74 = 216 Hz
                let v = if p < 37 { (p - 18) * 600 } else { (55 - p) * 600 };
                v.clamp(-16_000, 16_000) as i16
            })
            .collect();
        let r_alex = tracker.classify_and_learn(&alex_voice, 16_000, 2000, Some("Where do you know that?"));
        assert_eq!(r_alex.source, AcousticSourceKind::OtherSpeaker(0));
        assert_eq!(r_alex.source.as_str(), "alex");

        let hue_voice: Vec<i16> = (0..3200)
            .map(|i| {
                let p = (i % 103) as i32; // 16000 / 103 = 155 Hz
                let v = if p < 51 { (p - 25) * 520 } else { (77 - p) * 520 };
                v.clamp(-16_000, 16_000) as i16
            })
            .collect();
        let r_hue = tracker.classify_and_learn(&hue_voice, 16_000, 2003, Some("Hey Aye let us test this"));
        assert_eq!(r_hue.source, AcousticSourceKind::PrimaryUser);
        assert_eq!(r_hue.source.as_str(), "hue");
    }
}
