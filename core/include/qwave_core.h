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

/* Local reading ABI v1. Optional implementation in the SAME core archive.
 * Version 0 means unavailable; callers must keep the original page. No cloud
 * fallback, downloading, or speaker playback occurs at this boundary.
 * All input/output buffers must be valid for their lengths, non-overlapping,
 * and not concurrently mutated. UTF-8 JSON is length-delimited, not NUL-ended.
 * Handles/generations are process-local IDs, never pointers; 0 is invalid.
 * Run open/run off the UI thread. One session and one inference at a time.
 */
#define QW_READING_OK 0
#define QW_READING_UNAVAILABLE 1
#define QW_READING_INVALID_ARGUMENT 2
#define QW_READING_INVALID_HANDLE 3
#define QW_READING_BUSY 4
#define QW_READING_CANCELLED 5
#define QW_READING_MODEL_ERROR 6
#define QW_READING_BUFFER_TOO_SMALL 7
#define QW_READING_FAILED 8
#define QW_READING_MAX_JSON 65536

uint32_t qw_reading_abi_version(void);
/* Configuration: {"model_path":"/absolute/file.gguf",
 *                 "tokenizer_path":"/absolute/tokenizer.json"}.
 * The optional implementation verifies its pinned assets; no caller-supplied
 * hashes or download URLs. Host-owned model files must remain immutable.
 * out_handle is zero on failure; success must be paired with close once. */
uint32_t qw_reading_open(const uint8_t *config, size_t config_len,
                         uint64_t *out_handle);
/* Begin cancels all older generations. out_generation is zero on failure. */
uint32_t qw_reading_begin(uint64_t handle, uint64_t *out_generation);
/* Cancel the matching generation; 0 explicitly cancels the current one.
 * A late cancellation for an older generation cannot cancel a new one. */
uint32_t qw_reading_cancel(uint64_t handle, uint64_t generation);
/* Removes the handle immediately and cancels pending/running inference.
 * Running calls retain their session safely until they finish. */
uint32_t qw_reading_close(uint64_t handle);
/* Request (exactly one tagged task):
 * {"task":"translate","request":{"source_language":"ja",
 *   "target_language":"en","text":"..."}} -> {"text":"..."}
 * {"task":"summarize","sentences":["..."]} -> {"sentences":["..."]}
 * Only en/ja initially. Translation blocks <=4096 UTF-8 bytes; summary uses
 * 1..32 sentences <=1024 bytes each. Input JSON <=QW_READING_MAX_JSON bytes.
 * Output capacity must be >=QW_READING_MAX_JSON before inference begins.
 * Output is written only on success, without a NUL; *written=0 on any failure.
 * Busy returns immediately: do not enqueue retries for obsolete documents.
 * Recheck generation AND document identity before applying text or speech.
 * Translation is plain text, never HTML; summary sentences remain verbatim. */
uint32_t qw_reading_run(uint64_t handle, uint64_t generation,
                        const uint8_t *input, size_t input_len,
                        uint8_t *output, size_t output_capacity, size_t *written);

#ifdef __cplusplus
}
#endif

#endif /* QWAVE_CORE_H */
