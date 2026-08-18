// SPDX-License-Identifier: MIT
//
// Qwave overlay — not upstream WireGuard.
// Wraps the utun Device so qpacket_filter (zig-core) sees every IP packet
// the Go backend reads from / writes to the tunnel. WireGuardKit's adapter
// never hands packets to Swift; this is the only place a filter can sit
// without replacing the data plane.

package main

/*
#include <stdint.h>
#include <stddef.h>

int qpacket_filter(void *state, const uint8_t *packet, size_t len);

static int qwave_call_filter(void *state, const uint8_t *packet, size_t len) {
	if (state == NULL || packet == NULL) {
		return 0;
	}
	return qpacket_filter(state, packet, len);
}
*/
import "C"

import (
	"os"
	"sync"
	"sync/atomic"
	"unsafe"

	"golang.zx2c4.com/wireguard/tun"
)

var qwaveFilterState unsafe.Pointer

//export wgSetPacketFilter
func wgSetPacketFilter(state unsafe.Pointer) {
	atomic.StorePointer(&qwaveFilterState, state)
}

func wrapQwavePacketFilter(inner tun.Device) tun.Device {
	state := atomic.LoadPointer(&qwaveFilterState)
	if state == nil {
		return inner
	}
	return newFilteringTUN(inner, state, cAllow)
}

type allowFunc func(state unsafe.Pointer, packet []byte) bool

func cAllow(state unsafe.Pointer, packet []byte) bool {
	if len(packet) == 0 {
		return true
	}
	rc := C.qwave_call_filter(state, (*C.uint8_t)(unsafe.Pointer(&packet[0])), C.size_t(len(packet)))
	return rc == 0
}

type filteringTUN struct {
	inner tun.Device
	state unsafe.Pointer
	allow allowFunc
	mu    sync.Mutex
}

func newFilteringTUN(inner tun.Device, state unsafe.Pointer, allow allowFunc) *filteringTUN {
	return &filteringTUN{inner: inner, state: state, allow: allow}
}

func (f *filteringTUN) File() *os.File           { return f.inner.File() }
func (f *filteringTUN) Flush() error             { return f.inner.Flush() }
func (f *filteringTUN) MTU() (int, error)        { return f.inner.MTU() }
func (f *filteringTUN) Name() (string, error)    { return f.inner.Name() }
func (f *filteringTUN) Events() <-chan tun.Event { return f.inner.Events() }
func (f *filteringTUN) Close() error             { return f.inner.Close() }

func (f *filteringTUN) permits(buf []byte, offset, n int) bool {
	if n <= 0 || offset < 0 || offset+n > len(buf) {
		return true
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.allow(f.state, buf[offset:offset+n])
}

func (f *filteringTUN) Read(buf []byte, offset int) (int, error) {
	for {
		n, err := f.inner.Read(buf, offset)
		if err != nil || n == 0 {
			return n, err
		}
		if f.permits(buf, offset, n) {
			return n, nil
		}
	}
}

func (f *filteringTUN) Write(buf []byte, offset int) (int, error) {
	n := len(buf) - offset
	if n < 0 {
		n = 0
	}
	if !f.permits(buf, offset, n) {
		return n, nil
	}
	return f.inner.Write(buf, offset)
}
