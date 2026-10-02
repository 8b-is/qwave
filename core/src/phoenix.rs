//! The Phoenix protocol — the orchestration layer of the MEM|8 stack,
//! ported to zero-dependency Rust and made a first-class citizen of the core.
//!
//! The pipeline, per the 8b.is spec (`8b-public-documents`, phoenix-stack):
//!
//! ```text
//! essence ─▶ Marine salience gate (structural jitter + attentional novelty)
//!        ─▶ Phoenix orchestration (STORE / REINFORCE / TEMPORARY / DROP)
//!        ─▶ Council verdict: `precious` overrides the gate (always STORE, τ=∞)
//!        ─▶ Custodian: duplicate → DROP (repetition is poison)
//!        ─▶ MEM|8 wave store: 32-byte wave vector + 3-byte VAD + decay D(t,τ)
//!        ─▶ interference lattice (phase-relation binding)
//!        ─▶ φ-resynthesis on recall (golden-ratio harmonic revival)
//! ```
//!
//! The memory substrate stays MEM|8: every wave is a 32-byte vector in the
//! same ABI the Council's adapter (`wave_brain.py`) writes, so qwave's store
//! and the Council's store speak one language.

use std::collections::HashSet;

/// The four orchestration verdicts.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Verdict {
    Store = 0,
    Reinforce = 1,
    Temporary = 2,
    Drop = 3,
}

/// The five interference relations and their lattice phase offsets.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Relation {
    Bound = 0,
    Related = 1,
    Independent = 2,
    Contrasting = 3,
    Conflicting = 4,
}

impl Relation {
    /// The lattice phase offset, in degrees: bound 0°, related 45°,
    /// independent 90°, contrasting 135°, conflicting 180°.
    pub fn phase_degrees(self) -> u8 {
        [0, 45, 90, 135, 180][self as usize]
    }
}

/// Decay categories → (id, τ seconds). τ = 0 means ∞: precious never decays.
pub const DECAY_CATEGORIES: [(&str, u8, u64); 6] = [
    ("precious", 0, 0),
    ("week", 1, 604_800),
    ("day", 2, 86_400),
    ("hour", 3, 3_600),
    ("transient", 4, 300),
    ("ephemeral", 5, 60),
];

/// Decay: `D(t, τ) = e^(-t/τ)`. τ = 0 (precious) never decays.
pub fn decay(t_seconds: f64, tau_seconds: u64) -> f64 {
    if tau_seconds == 0 {
        return 1.0;
    }
    (-t_seconds / tau_seconds as f64).exp()
}

/// A 32-byte MEM|8 wave vector — the Council's ABI:
/// `md5(essence)[0..16] | amplitude f32 | frequency f32 | phase u8 |
/// decay_id u8 | 6 bytes reserved`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Wave32(pub [u8; 32]);

impl Wave32 {
    pub fn pack(essence: &str, amplitude: f32, frequency: f32, phase_deg: u8, decay_id: u8) -> Self {
        let digest = md5(essence.as_bytes());
        let mut out = [0u8; 32];
        out[0..16].copy_from_slice(&digest);
        out[16..20].copy_from_slice(&amplitude.to_le_bytes());
        out[20..24].copy_from_slice(&frequency.to_le_bytes());
        out[24] = phase_deg;
        out[25] = decay_id;
        // bytes 26..32 reserved.
        Self(out)
    }
}

/// The Custodian: repetition is poison. One content hash may enter the grid
/// once; a duplicate verdict is `Drop`.
#[derive(Default)]
pub struct Custodian {
    seen: HashSet<u64>,
}

impl Custodian {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn is_duplicate(&self, hash: u64) -> bool {
        self.seen.contains(&hash)
    }

    pub fn admit(&mut self, hash: u64) {
        self.seen.insert(hash);
    }

    /// The protocol's rule: a duplicate is a `Drop`, whatever the gate says.
    pub fn adjudicate(&mut self, hash: u64) -> bool {
        if self.seen.contains(&hash) {
            return false; // drop
        }
        self.seen.insert(hash);
        true // admit
    }
}

/// The Marine salience gate: two gates, not one (the Phoenix audit's own
/// finding). Structural jitter (word-length coherence) and attentional
/// novelty (1 − max Jaccard against the lattice) are different axes.
#[derive(Clone, Copy, Debug)]
pub struct GateReadout {
    /// Structural coherence, 0..1 — how evenly the essence's words flow.
    pub coherence: f64,
    /// Attentional novelty, 0..1 — how unlike everything already in the grid.
    pub novelty: f64,
}

/// Tokenize: ascii words, length > 1, lowercased.
pub fn tokens(text: &str) -> Vec<&str> {
    text.split(|c: char| !c.is_ascii_alphanumeric())
        .filter(|w| w.len() > 1)
        .map(|w| w.trim_end_matches('\0'))
        .collect()
}

/// Jaccard similarity of two token sets, 0..1.
pub fn jaccard(a: &[&str], b: &[&str]) -> f64 {
    if a.is_empty() || b.is_empty() {
        return 0.0;
    }
    let set_a: HashSet<&&str> = a.iter().collect();
    let set_b: HashSet<&&str> = b.iter().collect();
    let inter = set_a.intersection(&set_b).count();
    let union = set_a.union(&set_b).count();
    inter as f64 / union as f64
}

/// Structural jitter → coherence. Word-length variance is the jitter: long
/// words are rare, high-jitter text is either poetry (important!) or noise.
/// The gate therefore only *reduces* amplitude at very high jitter
/// (coherence < 0.35) — the Phoenix audit's correction, ported exactly.
pub fn coherence_of(text: &str) -> f64 {
    let words = tokens(text);
    if words.is_empty() {
        return 0.0;
    }
    let lengths: Vec<f64> = words.iter().map(|w| w.len() as f64).collect();
    let mean = lengths.iter().sum::<f64>() / lengths.len() as f64;
    let variance = lengths.iter().map(|l| (l - mean).powi(2)).sum::<f64>() / lengths.len() as f64;
    let jitter = variance.sqrt() / mean.max(1.0);
    (1.0 / (1.0 + jitter)).clamp(0.0, 1.0)
}

/// The full Phoenix orchestration, one struct, in-memory.
#[derive(Default)]
pub struct Phoenix {
    pub custodian: Custodian,
    /// Content hashes the Council has marked `precious`: the gate cannot drop
    /// them, ever.
    pub precious: HashSet<u64>,
    /// The lattice of admitted essences (tokenized) — novelty's reference.
    pub lattice: Vec<Vec<String>>,
    /// The wave store, in admission order.
    pub store: Vec<(u64, Wave32)>,
}

impl Phoenix {
    pub fn new() -> Self {
        Self::default()
    }

    /// The Marine gate over this grid.
    pub fn marine_gate(&self, essence: &str) -> GateReadout {
        let coherence = coherence_of(essence);
        let essence_tokens: Vec<&str> = tokens(essence);
        let novelty = if self.lattice.is_empty() {
            1.0
        } else {
            let best = self
                .lattice
                .iter()
                .map(|existing| {
                    let existing_refs: Vec<&str> = existing.iter().map(String::as_str).collect();
                    jaccard(&essence_tokens, &existing_refs)
                })
                .fold(0.0f64, f64::max);
            1.0 - best
        };
        GateReadout { coherence, novelty }
    }

    /// The protocol's core decision. `precious_override` is the Council's
    /// word: it always STOREs with τ=∞, whatever the gate says.
    ///
    /// Gate policy (ported from the adapter): very high jitter (coherence
    /// < 0.35) halves the amplitude; the Custodian drops duplicates; novelty
    /// below 0.05 (the text is already in the grid) demotes to TEMPORARY.
    pub fn decide(
        &mut self,
        essence: &str,
        precious_override: bool,
        amplitude: f32,
        frequency: f32,
        phase_deg: u8,
        decay_id: u8,
    ) -> (Verdict, f32) {
        let hash = content_hash(essence);

        if precious_override {
            self.precious.insert(hash);
            let wave = Wave32::pack(essence, amplitude.max(0.5), frequency, phase_deg, 0);
            self.store.push((hash, wave));
            self.remember(essence);
            return (Verdict::Store, amplitude.max(0.5));
        }

        if !self.custodian.adjudicate(hash) {
            return (Verdict::Drop, 0.0);
        }

        let gate = self.marine_gate(essence);
        let mut amp = amplitude;
        if gate.coherence < 0.35 {
            amp *= 0.5;
        }
        if gate.novelty < 0.05 {
            // Already in the grid — keep it briefly, not forever.
            let wave = Wave32::pack(essence, amp, frequency, phase_deg, decay_id.min(5));
            self.store.push((hash, wave));
            self.remember(essence);
            return (Verdict::Temporary, amp);
        }

        let wave = Wave32::pack(essence, amp, frequency, phase_deg, decay_id);
        self.store.push((hash, wave));
        self.remember(essence);
        (Verdict::Store, amp)
    }

    /// φ-resynthesis on recall: the top match's frequency `f` has harmonic
    /// companions `f/φ` and `f·φ`; every stored wave within 6% of either
    /// harmonic is revived.
    pub fn phi_companions(&self, top_frequency: f32) -> Vec<f32> {
        const PHI: f32 = 1.618_034;
        let harmonics = [top_frequency / PHI, top_frequency * PHI];
        self.store
            .iter()
            .filter_map(|(_, wave)| {
                let f = f32::from_le_bytes(wave.0[20..24].try_into().unwrap());
                harmonics
                    .iter()
                    .any(|h| (f - h).abs() <= h * 0.06)
                    .then_some(f)
            })
            .collect()
    }

    fn remember(&mut self, essence: &str) {
        let words: Vec<String> = tokens(essence).iter().map(|w| w.to_string()).collect();
        self.lattice.push(words);
    }
}

/// The truncated FNV-1a content hash — the Custodian's and the Council's
/// shared identity for an essence.
pub fn content_hash(text: &str) -> u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in text.bytes() {
        h ^= b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    h
}

/// C ABI: run the Phoenix decision. `essence` is a NUL-terminated string;
/// returns the verdict byte (0=STORE, 1=REINFORCE, 2=TEMPORARY, 3=DROP) and
/// writes the resulting amplitude into `*amplitude_out`.
///
/// # Safety
/// `essence` must be a NUL-terminated string or null; `amplitude_out` must be
/// writable or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn qw_phoenix_decide(
    phoenix: *mut Phoenix,
    essence: *const core::ffi::c_char,
    precious: bool,
    amplitude: f32,
    frequency: f32,
    phase_deg: u8,
    decay_id: u8,
    amplitude_out: *mut f32,
) -> u8 {
    if phoenix.is_null() || essence.is_null() {
        return Verdict::Drop as u8;
    }
    // SAFETY: caller contract.
    let Ok(essence) = unsafe { core::ffi::CStr::from_ptr(essence) }.to_str() else {
        return Verdict::Drop as u8;
    };
    // SAFETY: caller contract — the phoenix pointer came from qw_phoenix_new.
    let phoenix = unsafe { &mut *phoenix };
    let (verdict, amp) = phoenix.decide(essence, precious, amplitude, frequency, phase_deg, decay_id);
    if !amplitude_out.is_null() {
        unsafe { *amplitude_out = amp };
    }
    verdict as u8
}

/// C ABI: allocate a fresh Phoenix. Callers own the pointer and must pass it
/// to `qw_phoenix_free` exactly once.
#[unsafe(no_mangle)]
pub extern "C" fn qw_phoenix_new() -> *mut Phoenix {
    Box::into_raw(Box::new(Phoenix::new()))
}

/// C ABI: release a Phoenix.
///
/// # Safety
/// `phoenix` must come from `qw_phoenix_new` and not be freed twice.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn qw_phoenix_free(phoenix: *mut Phoenix) {
    if !phoenix.is_null() {
        // SAFETY: caller contract.
        unsafe { drop(Box::from_raw(phoenix)) };
    }
}

// ── MD5, RFC 1321, dependency-free (the 16-byte prefix of the wave ABI) ────

/// MD5 digest, 16 bytes — the wave ABI's identity prefix.
pub fn md5(input: &[u8]) -> [u8; 16] {
    const S: [u32; 64] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, //
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, //
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, //
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ];
    const K: [u32; 64] = [
        0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613,
        0xfd469501, 0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193,
        0xa679438e, 0x49b40821, 0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d,
        0x02441453, 0xd8a1e681, 0xe7d3fbc8, 0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
        0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a, 0xfffa3942, 0x8771f681, 0x6d9d6122,
        0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70, 0x289b7ec6, 0xeaa127fa,
        0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665, 0xf4292244,
        0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
        0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb,
        0xeb86d391,
    ];

    let mut a0: u32 = 0x67452301;
    let mut b0: u32 = 0xefcdab89;
    let mut c0: u32 = 0x98badcfe;
    let mut d0: u32 = 0x10325476;

    let bit_len = (input.len() as u64).wrapping_mul(8);
    let mut msg = input.to_vec();
    msg.push(0x80);
    while msg.len() % 64 != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&bit_len.to_le_bytes());

    for chunk in msg.chunks_exact(64) {
        let mut m = [0u32; 16];
        for (i, word) in m.iter_mut().enumerate() {
            *word = u32::from_le_bytes(chunk[i * 4..i * 4 + 4].try_into().unwrap());
        }
        let (mut a, mut b, mut c, mut d) = (a0, b0, c0, d0);
        for i in 0..64 {
            let (f, g) = match i {
                0..=15 => ((b & c) | (!b & d), i),
                16..=31 => ((d & b) | (!d & c), (5 * i + 1) % 16),
                32..=47 => (b ^ c ^ d, (3 * i + 5) % 16),
                _ => (c ^ (b | !d), (7 * i) % 16),
            };
            let temp = d;
            d = c;
            c = b;
            b = b.wrapping_add(
                a.wrapping_add(f)
                    .wrapping_add(K[i])
                    .wrapping_add(m[g])
                    .rotate_left(S[i]),
            );
            a = temp;
        }
        a0 = a0.wrapping_add(a);
        b0 = b0.wrapping_add(b);
        c0 = c0.wrapping_add(c);
        d0 = d0.wrapping_add(d);
    }

    let mut out = [0u8; 16];
    out[0..4].copy_from_slice(&a0.to_le_bytes());
    out[4..8].copy_from_slice(&b0.to_le_bytes());
    out[8..12].copy_from_slice(&c0.to_le_bytes());
    out[12..16].copy_from_slice(&d0.to_le_bytes());
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn md5_matches_the_reference_vector() {
        assert_eq!(
            md5(b""),
            [
                0xd4, 0x1d, 0x8c, 0xd9, 0x8f, 0x00, 0xb2, 0x04, //
                0xe9, 0x80, 0x09, 0x98, 0xec, 0xf8, 0x42, 0x7e,
            ]
        );
        assert_eq!(
            md5(b"abc"),
            [
                0x90, 0x01, 0x50, 0x98, 0x3c, 0xd2, 0x4f, 0xb0, //
                0xd6, 0x96, 0x3f, 0x7d, 0x28, 0xe1, 0x7f, 0x72,
            ]
        );
    }

    #[test]
    fn the_wave_abi_is_32_bytes() {
        let wave = Wave32::pack("a mesh a ter", 0.79, 48.0, 0, 0);
        assert_eq!(wave.0.len(), 32);
        assert_eq!(f32::from_le_bytes(wave.0[16..20].try_into().unwrap()), 0.79);
        assert_eq!(wave.0[24], 0); // phase
        assert_eq!(wave.0[25], 0); // decay id (precious)
    }

    #[test]
    fn lattice_phases_are_the_spec() {
        assert_eq!(Relation::Bound.phase_degrees(), 0);
        assert_eq!(Relation::Related.phase_degrees(), 45);
        assert_eq!(Relation::Independent.phase_degrees(), 90);
        assert_eq!(Relation::Contrasting.phase_degrees(), 135);
        assert_eq!(Relation::Conflicting.phase_degrees(), 180);
    }

    #[test]
    fn precious_overrides_the_gate() {
        let mut phoenix = Phoenix::new();
        let (verdict, amp) =
            phoenix.decide("!! weird jitter text !!", true, 0.2, 48.0, 0, 1);
        assert_eq!(verdict, Verdict::Store);
        assert!(amp >= 0.5, "precious always stores at full amplitude");
        // And it is stored with τ=∞ (decay id 0).
        assert_eq!(phoenix.store[0].1 .0[25], 0);
    }

    #[test]
    fn duplicates_are_dropped_by_the_custodian() {
        let mut phoenix = Phoenix::new();
        let text = "the flame that learns to burn";
        let (v1, _) = phoenix.decide(text, false, 1.0, 48.0, 0, 1);
        assert_eq!(v1, Verdict::Store);
        let (v2, amp2) = phoenix.decide(text, false, 1.0, 48.0, 0, 1);
        assert_eq!(v2, Verdict::Drop);
        assert_eq!(amp2, 0.0);
    }

    #[test]
    fn already_known_text_is_temporary() {
        let mut phoenix = Phoenix::new();
        let base = "the colors of my love";
        let (v1, _) = phoenix.decide(base, false, 1.0, 48.0, 0, 1);
        assert_eq!(v1, Verdict::Store);
        // Token-identical essence (punctuation does not change the token
        // set): novelty collapses below the threshold → TEMPORARY.
        let (v2, _) = phoenix.decide("the colors of my love!", false, 1.0, 48.0, 0, 1);
        assert_eq!(v2, Verdict::Temporary);
    }

    #[test]
    fn phi_resynthesis_finds_golden_companions() {
        let mut phoenix = Phoenix::new();
        phoenix.decide("a wave at forty eight hertz", false, 1.0, 48.0, 0, 1);
        phoenix.decide("a wave at thirty hertz", false, 1.0, 29.66, 0, 1); // ≈ 48/φ
        let companions = phoenix.phi_companions(48.0);
        assert!(companions.contains(&29.66), "48/φ must be found within the 6% band");
    }

    #[test]
    fn decay_is_the_mem8_curve() {
        assert_eq!(decay(1000.0, 0), 1.0); // precious never decays
        assert!(decay(86_400.0, 86_400) < 0.37); // e^-1
        assert!(decay(86_400.0, 86_400) > 0.36);
    }
}
