# arc-lock-benchmark — Synchronization primitives + ~Copyable, measured

Measured experiment (2026-08-14, Apple M1 Pro, macOS 26.4.1, Xcode 26.4.1,
`swift run -c release`). Two questions: do the new `synchronization`
primitives beat the classics under contention, and does `~Copyable` cut ARC
traffic at a real ABI boundary?

## 1. Locks — 8 threads x 2M increments (two samples)

| Primitive | sample A | sample B |
|---|---|---|
| `synchronization.Mutex<Int>` | 786.9 ms | 701.8 ms |
| `os_unfair_lock` (OSAllocatedUnfairLock) | 725.3 ms | 688.8 ms |
| `synchronization.Atomic<Int>` (relaxed) | 414.5 ms | **172.9 ms** |
| `NSLock` | 672.3 ms | 620.2 ms |
| `os_unfair_lock` (raw) | 788.0 ms | 531.0 ms |

Variance between runs is high (thermal/clock); the ordering is consistent:
**Atomic (lock-free) is 2-4x faster under contention; every lock-based
primitive ties.** The new `Mutex` is not faster than the classics on this
hardware — its value is ergonomics + safety, not speed.

## 2. ARC at an @inline(never) boundary — 50M calls, callee stores to a global

| Variant | ms |
|---|---|
| copyable, reused global | 893.8 |
| copyable, fresh per iteration | 377.6 |
| `~Copyable` consume, fresh per iteration | 377.7 |

**Parity.** With the fair comparison (fresh construction on both sides),
`~Copyable` buys nothing on a 40-byte struct with one class reference — the
copyable path's retain/release is already ~free (7.5 ns/call including
construction). Noncopyable's value is exclusivity semantics and large
buffers, not refcount churn on tiny values. The first run's "copyable wins"
was the reuse-vs-construct comparison — a benchmark design bug, caught by
adding the fair variant.

## Measured-hacking log

- `String(format: "%-28s", name)` with a Swift String crashes (SIGSEGV 139)
  — `%s` wants a C string. Use padding + `%@`.
- The first ARC run measured **zero refcount traffic**: an `@inline(never)`
  callee that only reads the parameter gets it at +0 (borrowed) — no
  retain/release happens. To force ARC, the callee must store the value.
- `~Copyable`: reading a field after `lastConsume = v` is a compile error
  ("used after consume") — read first, consume last.
- Swift 6: top-level mutable vars are MainActor-isolated; an
  `@inline(never)` global function touching them needs
  `nonisolated(unsafe)` on the vars.

```sh
swift run -c release
```
