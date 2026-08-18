/* SPDX-License-Identifier: MIT
 *
 * Qwave overlay — not upstream WireGuard.
 *
 * Weak default so `go test` of this package links without libqpacket.a.
 * PacketTunnel's Zig export is a strong `_qpacket_filter` and wins at
 * the final link.
 */

#include <stddef.h>
#include <stdint.h>

__attribute__((weak))
int qpacket_filter(void *state, const uint8_t *packet, size_t len)
{
    (void)state;
    (void)packet;
    (void)len;
    return 0;
}
