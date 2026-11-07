/* qwave-core.h — the sovereign core's C ABI.
 *
 * The Rust crate (core/) exposes the decisions to any language:
 * - whether a host is a permitted Category-A destination
 * - whether a 79-byte MEM8 wave frame is valid, and its grid coordinate
 * - the Phoenix protocol: STORE/REINFORCE/TEMPORARY/DROP orchestration over
 *   the MEM|8 wave store
 * - the mem|16-10 governing sequence (verification gate)
 * - PII-scrubbed URL export for the debug telemetry lane
 * - QuantTern emotional ternary code (VAD -> {-1, 0, +1} gate-coded byte)
 * - sphered membership badge witness & channel entitlement gate
 */
#ifndef QWAVE_CORE_H
#define QWAVE_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Egress: 1 when `host` is a permitted Category-A destination (exact match
 * or subdomain). Null, empty, or non-UTF8 hosts are never permitted. */
bool qw_egress_permits(const char *host);

/* Wave frame validation. `frame` must be 79 readable bytes or null.
 * Returns 0 when valid; 1 truncated, 2 unsupported version,
 * 3 invalid provenance, 4 invalid rational, 5 checksum mismatch. */
uint32_t qw_wave_frame_validate(const uint8_t *frame);

/* Grid coordinate of a validated frame at `now_nanos` (nanoseconds since
 * the Unix epoch). An invalid frame yields the origin (0, 0, 0). */
void qw_wave_frame_coord(const uint8_t *frame, uint64_t now_nanos,
                         uint8_t *x, uint8_t *y, uint16_t *z);

/* ── the Phoenix protocol (MEM|8 orchestration) ─────────────────────────── */

struct qwave_phoenix; /* opaque: the Rust Phoenix orchestration */

/* A fresh, empty orchestration. The caller owns the pointer and must pass
 * it to qw_phoenix_free exactly once. */
struct qwave_phoenix *qw_phoenix_new(void);

/* Release an orchestration created by qw_phoenix_new. */
void qw_phoenix_free(struct qwave_phoenix *phoenix);

/* Run one essence through the protocol: Marine gate → Custodian → Council.
 * Writes the resulting amplitude into *amplitude_out (when non-null) and
 * returns the verdict: 0 STORE, 1 REINFORCE, 2 TEMPORARY, 3 DROP.
 * `precious` is the Council's override: always STORE with τ=∞. */
uint8_t qw_phoenix_decide(struct qwave_phoenix *phoenix, const char *essence,
                          bool precious, float amplitude, float frequency,
                          uint8_t phase_deg, uint8_t decay_id,
                          float *amplitude_out);

/* ── mem|16-10 ───────────────────────────────────────────────────────────── */

/* The governing sequence's i-th step name ("POP"..."COLLAPSE"), or null out
 * of range. */
const char *qw_mem16_step_name(uint32_t i);

/* The verification gate: 1 for VERIFY (4) and COLLAPSE (5). */
bool qw_mem16_verified(uint32_t i);

/* ── telemetry (ultra-PII scrubbing) ─────────────────────────────────────── */

/* Write `url` with scheme+host kept and the path replaced by a truncated
 * hash into `out` (capacity `out_len` bytes, NUL-terminated). Returns bytes
 * written excluding the NUL; 0 on failure. */
size_t qw_telemetry_scrub_url(const char *url, char *out, size_t out_len);

/* ── QuantTern (qUltraKotoro emotional ternary code) ─────────────────────── */

/* Quantize (valence, arousal, dominance) in [-1, +1] to one gate-coded byte
 * (2 bits per trit, LSB first: -1 -> 0b00, 0 -> 0b01, +1 -> 0b10).
 * Pass threshold <= 0.0f to use the default 0.33f threshold. */
uint8_t qw_quanttern_encode(float valence, float arousal, float dominance,
                            float threshold);

/* Count of non-neutral trits (0..3) in a gate-coded VAD byte. */
uint8_t qw_quanttern_magnitude(uint8_t packed);

/* Agreement fraction in [0.0, 1.0] across the three VAD axes. */
float qw_quanttern_agreement(uint8_t packed_a, uint8_t packed_b);

/* ── sphered badge witness & channel gate (P1 membership spine) ──────────── */

/* Compute the deterministic 64-bit witness seal for a badge tuple. */
uint64_t qw_badge_seal(uint64_t member_hash, uint8_t tier,
                       uint64_t since_epoch, uint64_t until_epoch);

/* Verify a badge's 5-stage SpherePOP witness (#Commit = #ValidWitness). */
bool qw_badge_verify(uint64_t member_hash, uint8_t tier,
                     uint64_t since_epoch, uint64_t until_epoch,
                     uint64_t witness_seal);

/* Check whether `channel` (0 = stable, 1 = beta, 2 = nightly) is unlocked at
 * `now_epoch`. Channel 0 (stable) is unconditionally free for everyone. */
bool qw_channel_entitled(uint8_t channel, uint64_t member_hash, uint8_t tier,
                         uint64_t since_epoch, uint64_t until_epoch,
                         uint64_t witness_seal, uint64_t now_epoch);

/* Static NUL-terminated non-nagging notice for `channel`, or null. */
const char *qw_channel_notice(uint8_t channel);

/* ── PhoeniX Sound Revelation & Marine-Sense AUv3 DSP Engine ─────────────── */

struct qwave_phoenix_sound; /* opaque: real-time 16x Catmull-Rom + Svara + Marine engine */

/* Allocate a real-time PhoeniX audio processor at `sample_rate_hz` (`48000`..`384000`)
 * with `preset_id` (0=Sovereign, 1=GoonjVelvet, 2=NaadSub, 3=Sanctuary432, 4=VocalClarity). */
struct qwave_phoenix_sound *qw_phoenix_sound_new(uint32_t sample_rate_hz,
                                                 uint8_t preset_id);

/* Release a processor allocated by `qw_phoenix_sound_new`. */
void qw_phoenix_sound_free(struct qwave_phoenix_sound *engine);

/* Switch the active PhoeniX preset (`0..=5`, where `5 = AlexandraSanctuary`). */
void qw_phoenix_sound_set_preset(struct qwave_phoenix_sound *engine,
                                 uint8_t preset_id);

/* Update Auto-Magical Svara self-tuning and 3 human-feel macros (`0..=200` percent). */
void qw_phoenix_sound_set_feel(struct qwave_phoenix_sound *engine,
                               bool automagic,
                               uint16_t voice_pct,
                               uint16_t bass_pct,
                               uint16_t space_pct);

/* Toggle the built-in 432Hz x phi Alexandra Sanctuary Nervous-System Reset Wave. */
void qw_phoenix_sound_set_alexandra_reset(struct qwave_phoenix_sound *engine,
                                          bool active);

/* Fine-tune PhoeniX harmonic parameters (`0..=1024` Q10 scale; `stereo_width_q10` `512..=2048`). */
void qw_phoenix_sound_set_params(struct qwave_phoenix_sound *engine,
                                 int32_t naad_sub_q10,
                                 int32_t svara_vocal_q10,
                                 int32_t warmth_q10,
                                 int32_t goonj_velvet_q10,
                                 int32_t air_q10,
                                 int32_t stereo_width_q10);

/* Real-time zero-allocation in-place stereo `s16le` processing (`frames * 2` int16 samples). */
void qw_phoenix_sound_process_i16(struct qwave_phoenix_sound *engine,
                                  int16_t *interleaved_stereo,
                                  size_t frames);

/* Snapshot 64 Marine time-domain salience buckets (20 Hz .. 384 kHz), 64 isolated Singer-Only
 * vocal emotion buckets, dominant pitch (Hz), and Soul Authenticity score (0..1024). */
void qw_phoenix_sound_telemetry(const struct qwave_phoenix_sound *engine,
                                uint16_t *out_buckets_64,
                                uint16_t *out_vocal_64,
                                uint32_t *out_dom_hz,
                                uint16_t *out_soul_q10);

/* --- i1.is Sovereign AI Provenance, Soul Signature & Smart Tree .m8 --- */

struct QwI1DeedSummary {
    uint64_t soul_tag;
    uint64_t deed_seal;
    uint16_t stylometric_q10;
    uint16_t shingle_q10;
    uint16_t organic_authenticity_q10;
    uint16_t combined_match_q10;
    uint16_t smart_tree_savings_q10;
    uint16_t smart_tree_nodes;
    uint32_t redaction_count;
    bool can_ingest_i1;
    bool can_summarize_local;
};

bool qw_i1_evaluate_deed(const char *creator_id,
                         const char *secret_phrase,
                         const char *canonical_url,
                         const char *page_text,
                         uint8_t ingest_mode,
                         bool original_author_revoked,
                         struct QwI1DeedSummary *out_summary);

#ifdef __cplusplus
}
#endif

#endif /* QWAVE_CORE_H */
