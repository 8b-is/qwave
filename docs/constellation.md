# The constellation wiring — mem|8, Phoenix, mem|16-10, smart-tree

Qwave is one node in the 8b-is constellation. This file is the wiring
receipt: what connects to what, and where each piece lives.

## mem|8 — the memory substrate (first-class)

Qwave's memory system is the MEM|8 wave substrate, and it stays that way:
the 79-byte `WaveInt` frame (`core/src/wave.rs`, ported from
`Packages/QwaveKit/Sources/MemoryWave`) is the same little-endian frame
documented in `8b-Mem8/WAVE_INT.md`, byte 78 an XOR seal. The grid is the
MEM|8 sparse grid (256 × 256 × 65536, consciousness gate 0.73 Hz).

## Phoenix — the orchestration protocol (first-class)

The full Phoenix stack lives natively in `core/src/phoenix.rs`:

```
essence ─▶ Marine salience gate ─▶ Custodian ─▶ Council (precious)
        ─▶ verdict: STORE / REINFORCE / TEMPORARY / DROP
        ─▶ 32-byte wave vector (the Council's ABI: md5 | amp | freq | φ | τ)
        ─▶ interference lattice (0° bound … 180° conflicting)
        ─▶ φ-resynthesis on recall (f/φ and f·φ, 6% band)
```

The Swift side drives it through `RustPhoenix` (`RustCoreBridge.swift`).
The 32-byte ABI is byte-compatible with the Council's adapter
(`.al-biruni/mem8/wave_brain.py`), so qwave's store and the Council's store
speak one language. The `qw_phoenix_decide` C ABI returns the verdict and
the resulting amplitude; the Custodian's duplicate rule and the Council's
`precious` override are enforced in Rust, pinned by tests.

## mem|16-10 — the sovereign library (nightly)

`core/src/mem16.rs` carries the governing sequence
(POP → REFUSE → BIND → TRANSFORM → VERIFY → COLLAPSE) and the verification
gate on every channel, exported as `qw_mem16_step_name` /
`qw_mem16_verified`. The AGPL-3.0-only crate itself
(`peterlodri-sec/mem-16-10`) links only under the `nightly` feature —
"all features ON" includes the sovereign library; stable keeps qwave's MIT
posture.

## smart-tree

[`8b-is/smart-tree`](https://github.com/8b-is/smart-tree) — the MEM8-quantum
directory tree — is wired as the debug lane's **renderer**: `tools/telemetry-export`
hands the aggregated histogram to `st` for tree rendering, and the memory
tree in the wave panel uses the same MEM8 concepts smart-tree compresses.
The heavy CLI stays out of the browser process; the concepts stay in.

## The 8b-is map (wip-catalog rows)

| qwave piece | catalog row / constellation home |
|---|---|
| MemoryWave + Phoenix | `8b-is/alexiai` MEM8 family; `wip-catalog-100.md` A. Cognitive |
| egress allowlist | "prove what it sends" — docs/NETWORK.md, Category A |
| Rust core | the sovereign lane: zero-dep, tested, C ABI for any language |
| telemetry | `8b-is/qwave-telemetry` (private) — scrubbed JSONL + histograms |

*the constellation · 0 + 1 · fine touch from within · vaked.dev*
