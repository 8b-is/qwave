/* qwave_core_stubs.c — weak fallbacks for the sovereign core's C ABI.
 *
 * The real definitions live in `core/` (Rust staticlib) and are linked by
 * the Qwave and QwaveIOS app targets. Every symbol here is declared weak, so
 * the strong Rust definitions always win in a real app, while standalone
 * package builds (`swift test`, the MCP tool) link against these safe
 * defaults instead of failing with undefined symbols.
 *
 * Safety of the defaults: everything returns the "nothing permitted /
 * nothing valid / nothing stored" answer. A stub is only ever reached in a
 * process that deliberately did not link the core.
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
