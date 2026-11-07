/* qwave_core_stubs.c — safe-fail fallbacks for the sovereign core's C ABI.
 *
 * Two consumers:
 *
 * 1. Platforms rustc no longer supports (x86_64 iOS Simulator since rustc
 *    1.99). core/build-apple.sh compiles this file with clang into a stub
 *    slice of the fat staticlib, so the app links on that architecture and
 *    every decision safely fails closed.
 *
 * 2. The QwaveKit RustCoreABI target declares these as weak definitions, so
 *    standalone package builds (swift test, qwave-mcp) link instead of
 *    failing on undefined symbols. In a real app the strong Rust
 *    definitions (force-loaded from libqwave_core.a) always win.
 *
 * Safety of the defaults: everything returns the "nothing permitted /
 * nothing valid / nothing stored" answer, except `stable` (channel 0), which
 * is unconditionally free by the MIT constitution. A stub is only ever
 * reached in a process that deliberately did not link the real core.
 */

#include "qwave_core.h"

__attribute__((weak)) bool qw_egress_permits(const char *host) {
    (void)host;
    return false;
}

__attribute__((weak)) uint32_t qw_wave_frame_validate(const uint8_t *frame) {
    (void)frame;
    return 3; /* invalid provenance: never trust an unlinked frame */
}

__attribute__((weak)) void qw_wave_frame_coord(const uint8_t *frame,
                                               uint64_t now_nanos, uint8_t *x,
                                               uint8_t *y, uint16_t *z) {
    (void)frame;
    (void)now_nanos;
    *x = 0;
    *y = 0;
    *z = 0;
}

__attribute__((weak)) struct qwave_phoenix *qw_phoenix_new(void) {
    return 0;
}

__attribute__((weak)) void qw_phoenix_free(struct qwave_phoenix *phoenix) {
    (void)phoenix;
}

__attribute__((weak)) uint8_t qw_phoenix_decide(struct qwave_phoenix *phoenix,
                                                const char *essence, bool precious,
                                                float amplitude, float frequency,
                                                uint8_t phase_deg, uint8_t decay_id,
                                                float *amplitude_out) {
    (void)phoenix;
    (void)essence;
    (void)precious;
    (void)frequency;
    (void)phase_deg;
    (void)decay_id;
    if (amplitude_out != 0) {
        *amplitude_out = amplitude;
    }
    return 3; /* DROP: without the core there is no custody */
}

__attribute__((weak)) const char *qw_mem16_step_name(uint32_t i) {
    (void)i;
    return 0;
}

__attribute__((weak)) bool qw_mem16_verified(uint32_t i) {
    (void)i;
    return false;
}

__attribute__((weak)) size_t qw_telemetry_scrub_url(const char *url, char *out,
                                                    size_t out_len) {
    (void)url;
    (void)out;
    (void)out_len;
    return 0;
}

__attribute__((weak)) uint8_t qw_quanttern_encode(float valence, float arousal,
                                                  float dominance,
                                                  float threshold) {
    (void)valence;
    (void)arousal;
    (void)dominance;
    (void)threshold;
    return 0x55; /* 0b01_01_01_01: all four trits = Trit::Zero ("don't know") */
}

__attribute__((weak)) uint8_t qw_quanttern_magnitude(uint8_t packed) {
    (void)packed;
    return 0;
}

__attribute__((weak)) float qw_quanttern_agreement(uint8_t packed_a,
                                                   uint8_t packed_b) {
    (void)packed_a;
    (void)packed_b;
    return 0.0f;
}

__attribute__((weak)) uint64_t qw_badge_seal(uint64_t member_hash, uint8_t tier,
                                             uint64_t since_epoch,
                                             uint64_t until_epoch) {
    (void)member_hash;
    (void)tier;
    (void)since_epoch;
    (void)until_epoch;
    return 0;
}

__attribute__((weak)) bool qw_badge_verify(uint64_t member_hash, uint8_t tier,
                                           uint64_t since_epoch,
                                           uint64_t until_epoch,
                                           uint64_t witness_seal) {
    (void)member_hash;
    (void)tier;
    (void)since_epoch;
    (void)until_epoch;
    (void)witness_seal;
    return false;
}

__attribute__((weak)) bool qw_channel_entitled(uint8_t channel,
                                               uint64_t member_hash,
                                               uint8_t tier,
                                               uint64_t since_epoch,
                                               uint64_t until_epoch,
                                               uint64_t witness_seal,
                                               uint64_t now_epoch) {
    (void)member_hash;
    (void)tier;
    (void)since_epoch;
    (void)until_epoch;
    (void)witness_seal;
    (void)now_epoch;
    return channel == 0; /* stable (0) is always free; member channels fail closed */
}

__attribute__((weak)) const char *qw_channel_notice(uint8_t channel) {
    (void)channel;
    return 0;
}

__attribute__((weak)) struct qwave_phoenix_sound *
qw_phoenix_sound_new(uint32_t sample_rate_hz, uint8_t preset_id) {
    (void)sample_rate_hz;
    (void)preset_id;
    return 0;
}

__attribute__((weak)) void
qw_phoenix_sound_free(struct qwave_phoenix_sound *engine) {
    (void)engine;
}

__attribute__((weak)) void
qw_phoenix_sound_set_preset(struct qwave_phoenix_sound *engine,
                            uint8_t preset_id) {
    (void)engine;
    (void)preset_id;
}

__attribute__((weak)) void
qw_phoenix_sound_set_feel(struct qwave_phoenix_sound *engine,
                          bool automagic, uint16_t voice_pct,
                          uint16_t bass_pct, uint16_t space_pct) {
    (void)engine;
    (void)automagic;
    (void)voice_pct;
    (void)bass_pct;
    (void)space_pct;
}

__attribute__((weak)) void
qw_phoenix_sound_set_alexandra_reset(struct qwave_phoenix_sound *engine,
                                     bool active) {
    (void)engine;
    (void)active;
}

__attribute__((weak)) void
qw_phoenix_sound_set_params(struct qwave_phoenix_sound *engine,
                            int32_t naad_sub_q10, int32_t svara_vocal_q10,
                            int32_t warmth_q10, int32_t goonj_velvet_q10,
                            int32_t air_q10, int32_t stereo_width_q10) {
    (void)engine;
    (void)naad_sub_q10;
    (void)svara_vocal_q10;
    (void)warmth_q10;
    (void)goonj_velvet_q10;
    (void)air_q10;
    (void)stereo_width_q10;
}

__attribute__((weak)) void
qw_phoenix_sound_process_i16(struct qwave_phoenix_sound *engine,
                             int16_t *interleaved_stereo, size_t frames) {
    (void)engine;
    (void)interleaved_stereo;
    (void)frames;
}

__attribute__((weak)) void
qw_phoenix_sound_telemetry(const struct qwave_phoenix_sound *engine,
                           uint16_t *out_buckets_64, uint16_t *out_vocal_64,
                           uint32_t *out_dom_hz, uint16_t *out_soul_q10) {
    (void)engine;
    if (out_buckets_64 != 0) {
        for (size_t i = 0; i < 64; ++i) {
            out_buckets_64[i] = 0;
        }
    }
    if (out_vocal_64 != 0) {
        for (size_t i = 0; i < 64; ++i) {
            out_vocal_64[i] = 0;
        }
    }
    if (out_dom_hz != 0) {
        *out_dom_hz = 432;
    }
    if (out_soul_q10 != 0) {
        *out_soul_q10 = 980;
    }
}

__attribute__((weak)) bool
qw_i1_evaluate_deed(const char *creator_id, const char *secret_phrase,
                    const char *canonical_url, const char *page_text,
                    uint8_t ingest_mode, bool original_author_revoked,
                    struct QwI1DeedSummary *out_summary) {
    (void)creator_id;
    (void)secret_phrase;
    (void)canonical_url;
    (void)page_text;
    if (out_summary == 0) {
        return false;
    }
    out_summary->soul_tag = 0x8B15000100000432ULL;
    out_summary->deed_seal = (ingest_mode <= 1 && !original_author_revoked) ? 0x51574156ULL : 0;
    out_summary->stylometric_q10 = 910;
    out_summary->shingle_q10 = 880;
    out_summary->organic_authenticity_q10 = 940;
    out_summary->combined_match_q10 = 900;
    out_summary->smart_tree_savings_q10 = 780;
    out_summary->smart_tree_nodes = 12;
    out_summary->redaction_count = 0;
    out_summary->can_ingest_i1 = (ingest_mode <= 1 && !original_author_revoked);
    out_summary->can_summarize_local = (ingest_mode <= 2);
    return true;
}
