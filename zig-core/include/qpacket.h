#ifndef QPACKET_H
#define QPACKET_H

#include <stdint.h>
#include <stddef.h>

/// Initialize the packet filter. Returns an opaque handle or NULL on failure.
void *qpacket_filter_init(void);

/// Filter a single packet. Returns 0 (allow) or 1 (drop).
/// `state` is the handle from `qpacket_filter_init`.
/// `packet` points to the raw IP packet bytes.
/// `len` is the packet length in bytes.
int qpacket_filter(void *state, const uint8_t *packet, size_t len);

/// Read filter statistics.
void qpacket_filter_stats(void *state, uint64_t *seen, uint64_t *dropped);

/// Destroy the filter and free all resources.
void qpacket_filter_deinit(void *state);

#endif /* QPACKET_H */