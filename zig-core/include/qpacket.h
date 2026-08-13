#ifndef QPACKET_H
#define QPACKET_H

#include <stdint.h>
#include <stddef.h>

/// Extended packet statistics.
struct qpacket_stats {
    uint64_t packets_seen;
    uint64_t packets_dropped;
    uint64_t packets_tcp;
    uint64_t packets_udp;
    uint64_t packets_icmp;
    uint64_t packets_other;
    uint64_t packets_ipv4;
    uint64_t packets_ipv6;
    uint64_t bytes_seen;
};

/// Initialize the packet filter. Returns an opaque handle or NULL on failure.
void *qpacket_filter_init(void);

/// Filter a single raw IP packet. Returns 0 (allow) or 1 (drop).
/// `state` is the handle from `qpacket_filter_init`.
/// `packet` points to the raw IP packet bytes.
/// `len` is the packet length in bytes.
int qpacket_filter(void *state, const uint8_t *packet, size_t len);

/// Read basic filter statistics (seen and dropped counts).
void qpacket_filter_stats(void *state, uint64_t *seen, uint64_t *dropped);

/// Read extended filter statistics.
void qpacket_filter_stats_extended(void *state, struct qpacket_stats *stats);

/// Destroy the filter and free all resources.
void qpacket_filter_deinit(void *state);

#endif /* QPACKET_H */