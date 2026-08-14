# wave-fbm-benchmark — the shipped wave shader: Metal compute vs scalar CPU

Measured experiment (2026-08-14, Apple M1 Pro, macOS 26.4.1, Xcode 26.4.1,
`swift run -c release`).

Ports Qwave's `WaveScene.fragmentShader` ("Lost in the Math", 5-octave fbm +
domain warp) to a Metal compute kernel and a scalar Swift reference, and
times both at the real canvas resolution (1512x982, 1,484,784 pixels).
Color mixes are omitted (they do not change the ALU profile); the final fbm
value is written to a buffer and a global accumulator so nothing is
optimized away — verified by counting the 742M `sin` calls the CPU path
really executes per run.

## Results

| Path | ms/frame | fps potential |
|---|---|---|
| GPU (Metal compute, Apple M1 Pro) | **1.85** (kernel ~1.60; 1.8-2.5 across runs) | ~550 |
| CPU (scalar Swift, 1 core) | **757.72** | 1.32 |
| Speedup | **~409x** (473x vs kernel-only) | |

30fps cap budget (33.33 ms): the GPU kernel uses **~5.6%** of it.

## Why this matters for Qwave

1. The wave is ~400x too expensive for CPU. WebKit already renders the
   shipped WebGL shader in its GPU process (Metal underneath on Apple
   Silicon) — an app-side MTKView port would double-composite it, not
   speed it up.
2. The 30fps cap from the wave PR is nearly free in GPU time (5.6% of the
   frame budget at 1512x982) — the cap's real saving is energy per frame
   across N tabs, not frame budget.
3. The per-pixel cost is dominated by the 5 fbm calls (25 noise, ~100 sin
   per pixel). Resolution is the demand lever: halving canvas pixels
   quarters the kernel cost.

## Measured-hacking log (traps hit, in case you re-run this)

- **Sink elimination, twice.** A local `sink += ...` with a
  `withUnsafePointer(to:)` discard is provably dead — the optimizer removes
  the whole loop (measured 0.81ms/frame, i.e. nonsense). A never-read
  global is also dead. The global must be *read after timing* (printed) for
  the loop to survive; sin-call counting confirmed 742,392,000 executions.
- **Unit bug.** The CPU path returned seconds, the GPU path milliseconds;
  the first honest-looking run "proved" CPU faster than GPU. Check units
  before trusting a table.
- **MSL global constructors.** `constant float2x2 rot = float2x2(cos(0.5), ...)`
  fails library compile ("llvm.global_ctors") — bake the constants.
- **`import simd`.** Without it, `floor(SIMD2<Float>)` binds to
  Foundation's `floor(Double)` and the type-checker produces baffling
  "Duration" errors downstream.

```sh
swift run -c release
```
