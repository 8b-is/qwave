/* qwave-core.h — the sovereign core's C ABI.
 *
 * The Rust crate (core/) exposes exactly three decisions to any language:
 * whether a host is a permitted Category-A destination, whether a 79-byte
 * MEM8 wave frame is valid, and where a valid wave sits in the sparse grid.
 * Everything else stays inside the crate.
 */
#ifndef QWAVE_CORE_H
#define QWAVE_CORE_H

#include <stdbool.h>
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

#ifdef __cplusplus
}
#endif

#endif /* QWAVE_CORE_H */
