#include <jemalloc/jemalloc.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define QWAVE_STRINGIFY_(value) #value
#define QWAVE_STRINGIFY(value) QWAVE_STRINGIFY_(value)

static inline uint64_t qwave_allocation_count(void) {
    uint64_t epoch = 1, small = 0, large = 0;
    size_t size = sizeof(uint64_t);
    if (mallctl("thread.tcache.flush", NULL, NULL, NULL, 0) ||
        mallctl("epoch", NULL, NULL, &epoch, sizeof(epoch)) ||
        mallctl("stats.arenas." QWAVE_STRINGIFY(MALLCTL_ARENAS_ALL) ".small.nrequests",
                &small, &size, NULL, 0)) {
        fprintf(stderr, "Could not read jemalloc allocation counters\n");
        abort();
    }
    size = sizeof(uint64_t);
    if (mallctl("stats.arenas." QWAVE_STRINGIFY(MALLCTL_ARENAS_ALL) ".large.nrequests",
                &large, &size, NULL, 0)) {
        fprintf(stderr, "Could not read jemalloc large-allocation counter\n");
        abort();
    }
    return small + large;
}

static inline const char *qwave_jemalloc_version(void) {
    return JEMALLOC_VERSION;
}
