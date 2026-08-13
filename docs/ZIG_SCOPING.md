# Zig Kernel — Scoping Analysis for Qwave

> Companion to `docs/SWIFT_ZIG_INTEROP_PLAYBOOK.md`. Evaluates where Zig could earn its place in Qwave, in priority order.

---

## Candidate 1: PacketTunnel data plane (STRONGEST FIT)

**Pattern:** Hot kernel — stateless `export fn`s over caller buffers.

**What:** The NE tunnel (`Sources/PacketTunnel`) processes packets in the data plane. This is a tight loop over bytes where Zig's `ReleaseSafe` bounds checking, `@Vector` SIMD, and arena allocation would be directly useful.

**Integration:** Same XcodeGen build-phase pattern as the WireGuard Go bridge — `preBuildScripts` calling `zig build`, output linked as a static lib. The proven pattern already exists in the project.

**Cost:** ~100-200 lines of Zig, one C header (~20 lines). No runtime to ship, no ABI negotiation.

**Risk:** Low. The boundary is a pure hot loop; no state, no lifecycle.

---

## Candidate 2: SparseWaveGrid / WaveInt binary frame (NATURAL FIT)

**Pattern:** Libghostty — Zig owns long-lived state behind an opaque handle.

**What:** `SparseWaveGrid` is a 256×256×65536 sparse grid with `WaveInt` (79-byte fixed-size binary frames). The `resonate` query is a hot path with floating-point math and Dictionary lookups. The `WaveInt` binary frame is exactly the shape of problem Zig's `extern struct` solves — deterministic layout, no ARC, no Foundation overhead.

**Why Zig over Swift:**
- `WaveInt` deserialization currently uses `Data` + manual offset math. An `extern struct` with `@bitCast` is zero-overhead.
- `SparseWaveGrid.query(bounds:)` filters on every entry. In Zig, this is a tight loop over a `std.ArrayList` with arena allocation — no ARC traffic, no COW copies.
- `resonate` ranks by frequency delta. In Zig, this is a bounded partial sort (same pattern as the M1 omnibox optimization) with `@Vector` for the delta computation.

**Integration:** Recipe C (XcodeGen build phase) or Recipe A (XCFramework via `zig build-lib` + `lipo`). The `WaveInt` frame is stable (79 bytes, defined in 8b-Mem8/WAVE_INT.md), so the ABI is fixed.

**Cost:** ~300-500 lines of Zig, one C header, one XCFramework build step. The existing `WaveInt` Swift implementation stays as the reference — the Zig kernel is a drop-in replacement behind the same API.

**Risk:** Medium. The MemoryWave module is new (v0.4.0) and still evolving. The ABI lock-in from a Zig kernel is premature if the data format is still changing.

---

## Candidate 3: UBORuleListCompiler (WEAK FIT)

**Pattern:** Hot kernel, but not the right tool.

**What:** The uBO/EasyList filter compiler is pure string processing with regex. Zig's string handling is UTF-8 byte slices (`[]const u8`) with no `NSRegularExpression` equivalent. The Swift Foundation regex engine is more productive here.

**Verdict:** Keep in Swift. The compiler is already fast enough (2.84s for 59k rules) and not a hotspot.

---

## Candidate 4: PostQuantum cross-check lane (OFF-LIMITS)

**Pattern:** Crypto cross-check, but constrained.

**What:** `std.crypto` includes ML-KEM in recent versions. A second implementation lane fed by the same KAT fixtures would be a genuine validation win.

**Constraint:** The handoff explicitly forbids touching crypto. If this is pursued, it must be in a separate session with a dedicated crypto review.

**Verdict:** Deferred. The idea is sound; the timing is not this session.

---

## Candidate 5: CLI companion tools (OPPORTUNISTIC)

**Pattern:** Toolchain only — single static binary.

**What:** `zig build -Dtarget=…` produces a tiny, no-runtime binary. Candidates:
- `scripts/update-blocklist.sh` replacement — a Zig binary that fetches, compiles, and writes the EasyList snapshot
- `scripts/release.sh` helper — signing, notarization, DMG creation
- Blocklist diff tool — compare two EasyList versions and report new/removed rules

**Cost:** ~50-100 lines each, trivial to build and ship.

**Verdict:** Low effort, useful, no downside. Good first Zig commit.

---

## Recommended path

1. **CLI tool first** — a Zig binary that replaces `scripts/update-blocklist.sh`. This is the "hello world" that proves the Zig toolchain works in CI, takes ~1 hour, and has no risk.
2. **PacketTunnel data plane** — the strongest architectural fit, using the proven WireGuard Go bridge build pattern.
3. **SparseWaveGrid** — after the v0.4.x MemoryWave API stabilizes. The `WaveInt` 79-byte frame is a textbook Zig problem.

**Not recommended:** UBORuleListCompiler (Swift is better), PostQuantum (off-limits).