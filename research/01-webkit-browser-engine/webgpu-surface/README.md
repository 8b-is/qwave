# webgpu-surface — WebGPU feature surface probe for Qwave's engine

Version-stamped probe of the WebGPU surface WebKit exposes to a WKWebView
on this machine, plus the three-browser comparison and the flag experiment.
Local-only: `Probe/probe.html` is a file URL, zero network.

**Stamps (2026-08-14T14:40Z):** macOS 26.4.1 (25E253) · WebKit 21624 ·
Swift 6.3 / Xcode 26.4.1 · Chrome 151.0.7922.138 · Safari 26.4 ·
Qwave @ main (9b31097+). WebGPU surfaces move monthly; an undated copy of
this matrix is misinformation in six weeks.

## Findings (WKWebView, baseline — no flags touched)

1. **`navigator.gpu` is TRUE by default.** The research brief's
   2026-08-13 addendum — "gated behind `_WKFeature` `WebGPUEnabled`" — is
   **resolved as stale**: on this build the surface is default-on and the
   flag is gone (see 3). Surfaces moved within a day of the brief; this is
   the citation that replaces it.
2. **18-19 adapter features, all individually granted** via
   `requestDevice({ requiredFeatures: [f] })` (18/18 or 19/19, one feature
   flapped across runs — logged, not fought): `shader-f16`,
   `timestamp-query`, `float16/float32-{renderable,filterable,blendable}`,
   `depth-clip-control`, `depth32float-stencil8`, `indirect-first-instance`,
   BC/ASTC/ETC2 texture compression (+ sliced 3D), `rg11b10ufloat-renderable`,
   `core-features-and-limits`. **No subgroups**, no dual-source-blending,
   no multi-draw-indirect.
3. **The `_features` SPI is alive — at the CLASS level (CORRECTED).** The
   first probe checked `WKPreferences` instance-level `responds(to:)` and
   reported an "empty list". That was the probe's own instance-vs-class
   artifact: on WebKit 21624, `_features` responds on `WKPreferences.self`
   (596 features; `_experimentalFeatures` 220, `_internalDebugFeatures`
   142, all with parseable keys) while an instance does not. The app's
   `FeatureFlagService` checks class-first and works. The probe now mirrors
   the app's class-first merged enumeration (see #40 for the tri-state
   hardening this surfaced).
4. **Flag experiment (redo, class-level): 11 WebGPU-related flags exist —
   and `WebGPUEnabled` is inert.** Toggling `WebGPUEnabled` OFF in a fresh
   ephemeral view leaves `navigator.gpu === true`; HDR/WebXR flags likewise
   change nothing. The flag is on the surface but no longer gates WebGPU —
   default-on regardless. Isolation assert: `qwave.featureFlagOverrides`
   byte-identical before/after (True).
4. **Compute runs.** Minimal WGSL compute dispatch (1M×32-bit adds, 10
   dispatches): **OK, 10.5M invocations in 13 ms** inside the web view.

## Three-browser comparison (feature EXPOSURE, not engine speed)

| Column | WKWebView | Chrome 151 | Safari 26.4 |
|---|---|---|---|
| automated | measured (results/wkwebview.json) | **hung** | **blocked** |
| `navigator.gpu` | true | not captured | not captured |

- **Chrome**: `--headless=new --dump-dom` leaves the probe at "running…"
  (never completes `requestAdapter`; two attempts, two profiles, GPU init
  in headless). Manual step: open `Probe/probe.html` in Chrome, copy the
  `<pre id="result">` content into `results/chrome-manual.json`.
- **Safari**: `osascript` `do JavaScript` refused — "Allow JavaScript from
  Apple Events" is off. Manual step: same page in Safari, copy the `<pre>`.
- Anti-hype: this matrix measures which optional features each engine
  EXPOSES. Nothing here is a speed claim.

## Three-way wave benchmark (P2) — WebGPU leg measured

The parked recipe is executed for the WebGPU leg; workload identical to
`wave-fbm-benchmark` (1512×982, 5 fbm calls/px, baked rotation constants).
Timing protocol mirrors the Metal leg: 1 warmup, 5 windows × 10 frames
bracketing `onSubmittedWorkDone`, empty-dispatch overhead subtracted;
timer resolution reported (WebKit coarsens `performance.now()` to ~1 ms —
quantization is material, so frames are batched per window).

| Leg | ms/frame | notes |
|---|---|---|
| CPU (scalar Swift, 1 core) | 757.72 (quiet-machine canonical; 200–757 across today's noisy samples) | checksum 732,590 — different sin library, ~18% loose |
| Metal compute (M1 Pro) | 1.85 (kernel ~1.6; 1.8–4.0 across noisy samples) | checksum 877,955 |
| **WebGPU-in-WKWebView (f32)** | **1.9–2.2** | **checksum 891,444 — 1.5% vs Metal (same-sin path)** |
| WebGPU-in-WKWebView (f16 variant) | 1.9–2.2 | labeled variant — f16 buys nothing on this kernel; checksum readback parked (Float16Array harness detail) |

Headline: **Qwave's embedded engine runs the wave at ~Metal kernel speed**
(WebGPU adds ~0.3 ms over the raw Metal leg — both land on the same GPU).
Machine was under varying load during several samples; conditions are
stamped per run in the committed JSON.

## P2 decision — three-way wave benchmark: parked, capability proven

The P1 surface is NOT too limited: WGSL compute dispatched and completed
(13 ms / 10.5M invocations). So the full three-way (CPU 757.72 ms vs Metal
1.85 ms vs WebGPU-in-Qwave) is parked with its recipe, not skipped for
lack of capability: port `WaveScene.fragmentShader`'s fbm to WGSL, same
1512×982 buffer, same iteration counts, same two-sample honesty, one extra
column for `shader-f16` on/off (f16 present in the matrix). It did not fit
this session; it is the natural next probe.

## Measured-hacking log

- **Chrome headless hangs at `requestAdapter`** (probe stays "running…") —
  dumped DOM confirms JS started; the GPU request never settles. Not
  fought after two attempts.
- **Safari automation needs the Developer toggle** — error 8, documented
  manual step.
- **My first probe edit scoped `adapter` wrong** — the compute check
  landed outside the `navigator.gpu` branch; `ReferenceError: adapter` on
  first run. Repositioned inside the branch; the error itself proved the
  probe's failure path is captured (out.error is populated, not silent).
- **Feature-count flap 19→18 across runs** — one optional feature dropped
  on the second run; recorded, not assumed stable.
- **`adapter.info` and `adapter.limits` stringify as `{}`** on WebKit —
  the JS-side spread yields nothing enumerable; the matrix uses
  `adapter.features` + per-feature `requestDevice` grants instead (the
  robust signal).

## Reproduce

```sh
cd research/01-webkit-browser-engine/webgpu-surface
swift run -c release          # WKWebView probe -> results/wkwebview.json
# Chrome/Safari: open Probe/probe.html, copy the <pre> content.
```
