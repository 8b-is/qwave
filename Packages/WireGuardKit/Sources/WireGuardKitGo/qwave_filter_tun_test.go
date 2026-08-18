// SPDX-License-Identifier: MIT
//
// Qwave overlay — not upstream WireGuard.

package main

import (
	"bytes"
	"errors"
	"os"
	"testing"
	"unsafe"

	"golang.zx2c4.com/wireguard/tun"
)

type fakeTUN struct {
	reads  [][]byte
	writes [][]byte
	closed bool
}

func (f *fakeTUN) File() *os.File           { return nil }
func (f *fakeTUN) Flush() error             { return nil }
func (f *fakeTUN) MTU() (int, error)        { return 1420, nil }
func (f *fakeTUN) Name() (string, error)    { return "utun-fake", nil }
func (f *fakeTUN) Events() <-chan tun.Event { return nil }
func (f *fakeTUN) Close() error             { f.closed = true; return nil }

func (f *fakeTUN) Read(buf []byte, offset int) (int, error) {
	if len(f.reads) == 0 {
		return 0, errors.New("no more packets")
	}
	pkt := f.reads[0]
	f.reads = f.reads[1:]
	copy(buf[offset:], pkt)
	return len(pkt), nil
}

func (f *fakeTUN) Write(buf []byte, offset int) (int, error) {
	pkt := append([]byte(nil), buf[offset:]...)
	f.writes = append(f.writes, pkt)
	return len(pkt), nil
}

func ipv4TCP() []byte {
	pkt := make([]byte, 40)
	pkt[0] = 0x45
	pkt[2] = 0
	pkt[3] = 40
	pkt[9] = 6
	return pkt
}

func shortGarbage() []byte { return []byte{0x45, 0, 0, 0, 0} }

func TestWrapNilStateIsIdentity(t *testing.T) {
	atomicStoreNil()
	inner := &fakeTUN{}
	if wrapQwavePacketFilter(inner) != inner {
		t.Fatal("nil filter state should leave the tun unwrapped")
	}
}

func TestReadDropsThenReturnsNext(t *testing.T) {
	good := ipv4TCP()
	inner := &fakeTUN{reads: [][]byte{shortGarbage(), good}}
	ft := newFilteringTUN(inner, unsafe.Pointer(uintptr(1)), func(_ unsafe.Pointer, pkt []byte) bool {
		return len(pkt) >= 20
	})

	buf := make([]byte, 128)
	n, err := ft.Read(buf, 4)
	if err != nil {
		t.Fatal(err)
	}
	if n != len(good) || !bytes.Equal(buf[4:4+n], good) {
		t.Fatalf("got %x want %x", buf[4:4+n], good)
	}
}

func TestWriteDropDoesNotReachInner(t *testing.T) {
	inner := &fakeTUN{}
	ft := newFilteringTUN(inner, unsafe.Pointer(uintptr(1)), func(_ unsafe.Pointer, _ []byte) bool {
		return false
	})

	buf := make([]byte, 4+len(shortGarbage()))
	copy(buf[4:], shortGarbage())
	n, err := ft.Write(buf, 4)
	if err != nil {
		t.Fatal(err)
	}
	if n != len(shortGarbage()) {
		t.Fatalf("drop should still report %d bytes, got %d", len(shortGarbage()), n)
	}
	if len(inner.writes) != 0 {
		t.Fatalf("dropped write leaked to utun: %d", len(inner.writes))
	}
}

func TestWriteAllowReachesInner(t *testing.T) {
	inner := &fakeTUN{}
	pkt := ipv4TCP()
	ft := newFilteringTUN(inner, unsafe.Pointer(uintptr(1)), func(_ unsafe.Pointer, _ []byte) bool {
		return true
	})

	buf := make([]byte, 4+len(pkt))
	copy(buf[4:], pkt)
	n, err := ft.Write(buf, 4)
	if err != nil || n != len(pkt) {
		t.Fatalf("write n=%d err=%v", n, err)
	}
	if len(inner.writes) != 1 || !bytes.Equal(inner.writes[0], pkt) {
		t.Fatalf("inner writes = %x", inner.writes)
	}
}

func atomicStoreNil() {
	wgSetPacketFilter(nil)
}
