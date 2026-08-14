# Bleeding-Edge Mac Stack — Research Brief

**Scope:** Apple Silicon · Metal · WebGPU · WebAssembly · Swift · Zig — topics, concepts, and open-source packages.
**Date:** 2026-08-13. Compiled from three parallel research sweeps against primary sources (developer.apple.com, webkit.org, w3.org, swift.org, ziglang.org, GitHub/Codeberg releases). Items are labeled **shipped / announced / proposal / rumored**; an aggregated caveats list is at the end — several Apple/W3C pages were reachable only via search snapshots, so spot-check flagged numbers before quoting them anywhere formal.

> **Qwave-verified addendum (2026-08-13, this repo):** Hook 1 below
> ("Qwave's WKWebView inherits Safari 26's WebGPU") was probed empirically
> on a macOS 26 host and is **wrong as stated**: `navigator.gpu` is
> `undefined` in a default `WKWebView`. WebGPU for embedders is gated
> behind the `_WKFeature` key **`WebGPUEnabled`** (alongside
> `WebGPUHDREnabled` and `WebXRWebGPUBindingsEnabled`) **and** requires a
> secure context. With the flag set via `_setEnabled:forFeature:` — the
> exact reflection pattern `FeatureFlagService` already uses — and a
> secure-context page, `navigator.gpu` is a live object. So for Qwave the
> correct claim is: WebGPU is one FeatureFlags toggle away, not inherited.
> (CI caveat: Blacksmith runners are macOS 15 / Safari 18-era WebKit — no
> WebGPU there; any test asserting it must stay local-only or
> availability-guarded.)
>
> **RESOLVED (2026-08-14, CORRECTED):**
> `research/01-webkit-browser-engine/webgpu-surface/` re-probed this on
> macOS 26.4.1 / WebKit 21624: `navigator.gpu` is **default-on** in a plain
> WKWebView, 18-19 adapter features all granted individually (incl.
> `shader-f16`, `timestamp-query`; no subgroups), and WGSL compute
> dispatches OK. The `_features` SPI is **alive at the CLASS level** (596
> features on `WKPreferences.self`; instance responds-to is false — an
> earlier probe's "empty list" was its own instance-level artifact).
> `WebGPUEnabled` still exists on the surface but is **inert**: disabling
> it leaves `navigator.gpu === true`. The three-way wave benchmark (CPU /
> Metal / WebGPU-in-Qwave) ran at 757.72 ms / 1.85 ms / ~2 ms per frame.
> The flag-gated statement above is stale; the probe is the citation.

---

## TL;DR — ten things that matter right now

1. **M5-generation GPUs have real tensor cores** ("Neural Accelerators", one per GPU core), programmable via Metal 4's `MTLTensor` + Metal Performance Primitives — >4× M4 GPU AI compute. M5 Pro/Max (Mar 2026) go to 614 GB/s unified memory.
2. **Metal 4 is a new API generation** (shipped, macOS 26 Tahoe, Apple-silicon-only): rebuilt command model, explicit residency, ML command encoder on the GPU timeline, MetalFX frame interpolation + denoising. MSL is at 4.1.
3. **macOS 27 "Golden Gate" (announced, fall 2026) drops Intel entirely**; Xcode 27 is Apple-silicon-only with a heavy agentic-coding push (Agent Client Protocol, MCP plugins).
4. **WebGPU now ships in every major browser** — including **Safari 26 (Sept 2025)**, implemented directly on Metal; Apple says WebGPU supersedes WebGL on its platforms. Firefox completed Mac rollout Jan 2026.
5. **Wasm 3.0 is the standard** (Sept 2025): GC, tail calls, memory64, relaxed SIMD, EH bundled. **JSPI** is the last big engine gap and it's in **Safari 27 beta** — all three engines by this fall.
6. **WASI 0.3 (June 2026) brings native async to the component model**; WASI 1.0 + Component Model 1.0 targeted late 2026/early 2027. jco transpiles components for browsers using JSPI.
7. **Swift 6.3 is current** (`@c` C-export, official Android SDK, prebuilt swift-syntax macros); **6.4 in beta** with Xcode 27. Wasm is an **officially supported Swift platform** since 6.2; concurrency got "approachable" (default-MainActor mode, `@concurrent`).
8. **Zig 0.16** landed `std.Io` — colorless async I/O passed like an `Allocator`, with io_uring/kqueue/GCD backends; 0.17 (imminent) reworks the build system (~90% faster `zig build`). Zig moved to Codeberg; 1.0 still unscheduled.
9. **Apple's ML stack reorganized at WWDC26**: new **Core AI** framework (Core ML's successor, 3B–70B on-device inference), Foundation Models opened to third-party server models (Claude/Gemini Swift packages) and being **open-sourced summer 2026**; MLX v0.32 adds a CUDA backend and multi-Mac RDMA/TB5 training.
10. **The Zig-core-in-a-Swift-shell pattern is now productized**: Ghostty 1.3 extracted **libghostty** (Zig static lib + C API consumed from SwiftUI) — the reference architecture for mixing the two on Mac.

---

## 1. Apple Silicon

**Shipped:** M5 (Oct 2025 — 3nm N3P, 10-core GPU with per-core Neural Accelerators, 3rd-gen ray tracing, 153 GB/s, 32 GB max) · **M5 Pro / M5 Max** (Mar 2026). New **three-tier core naming**: "super cores" (renamed P-cores) + a new mid "performance core" tier; Pro/Max drop E-cores entirely. M5 Max: 18-core CPU, up to 40-core GPU, **614 GB/s**, 128 GB. Mac Studio still M4 Max/M3 Ultra; Mac Pro still M2 Ultra.
**Rumored:** M5 Ultra Mac Studio ~Oct 2026 (up to 768 GB, delayed by DRAM shortage); M6 (2nm) in a redesigned MacBook Pro late 2026/2027.

- **Matrix units:** since M4 the private AMX became architecturally exposed **ARM SME** (streaming SVE, 512-bit SVL) — programmable via clang `arm_sme.h`, consumed by Accelerate/BNNS. (SME2-on-M5: unverified.) No full non-streaming SVE on Apple cores.
- **M5 GPU microarchitecture** (Apple Tech Talk 111431): 2× FP16 ALU rate, 2× geometry, 2nd-gen dynamic caching, redesigned occupancy management, RT with hardware instance transforms (~-70% GPU time vs emulation), accel-structure alignment 16 KB→1 KB, 32K textures.
- **OS/tooling:** macOS 26 Tahoe = last Intel release; **macOS 27 Golden Gate** (fall 2026) is Apple-silicon-only. **Xcode 27**: ~30% smaller, Device Hub replaces Simulator, Agent Client Protocol + MCP plugin support, built-in specialist agents; Mac App Store accepts arm64-only binaries.

**Concepts:** *Unified memory* — CPU/GPU/ANE share one pool; a 128 GB M5 Max holds a quantized 70B-class model fully GPU-accessible; bandwidth, not VRAM, is the ceiling. *TBDR* — tile-based deferred rendering makes memoryless render targets, on-chip 8× MSAA, and tile shaders cheap. *SME* — CPU-side matrix compute distinct from GPU Neural Accelerators.

## 2. Metal

**Metal 4** (shipped with macOS 26; M1+/A14+ only):
- New `MTL4CommandQueue`/`MTL4CommandBuffer`: device-allocated, parallel-encoded, explicit sync (barriers/events) — much thinner CPU cost.
- Consolidated encoders; **`MTL4MachineLearningCommandEncoder`** schedules whole networks on the GPU timeline next to render/compute; **`MTLTensor`** is a first-class resource with tensor ops *inside shaders* (neural materials/lighting).
- Explicit **residency sets**, argument tables, placement sparse resources (forgetting residency is the new classic crash).
- **MetalFX**: upscaling + **frame interpolation + RT denoising**; the WWDC26 temporal upscaler runs its network on the Neural Engine/GPU Neural Accelerators.
- **WWDC26**: quantized tensor formats with scale factors (mapped to M5 Neural Accelerators), **Game Porting Toolkit 4** (now on Apple's official GitHub, with an *agent-skills* companion for AI-assisted porting), Metal CLI tools designed for agent-driven debugging, MSL 4.1.
- Mesh shaders/function pointers: carried from Metal 3. **No Metal equivalent of D3D12 GPU work graphs.**

**Vulkan-on-Metal:** MoltenVK v1.4.2 (Jul 2026, near-conformant Vulkan 1.4) — and the new **KosmicKrisp** (LunarG, Oct 2025): a Mesa-native Vulkan-on-Metal driver, Vulkan 1.3 CTS-conformant, Google-backed, shipping alongside MoltenVK in the Vulkan macOS SDK.

## 3. ML on Mac

- **MLX** (`ml-explore/mlx`, v0.32.0 Jul 2026, ~28k★): Apple's array framework — lazy eval, unified memory, Metal 4 + Neural Accelerator exploitation, **full CUDA backend** (train on NVIDIA, deploy on Mac), DLPack zero-copy, **multi-Mac distributed training over RDMA/Thunderbolt 5**. `mlx-swift` 0.31.6, `mlx-lm` for LLM inference/finetuning.
- **Foundation Models framework** (shipped OS 26): Swift API to the on-device ~3B model, guided generation + tool calling. **WWDC26:** multimodal prompts, **third-party server models via the LanguageModel protocol (Anthropic Claude and Google Gemini Swift packages)**, Python SDK, evals, free Private Cloud Compute tier, **open-source release summer 2026**.
- **Core AI** (announced WWDC26, session 324): Core ML's successor — memory-safe Swift inference API, PyTorch conversion, custom GPU kernels, AOT compilation, stateful execution, positioned for 3B–70B models. Rule of thumb: Core ML = legacy deployment; MLX = research/hacking; **Core AI = production inference going forward**; Foundation Models = Apple's own + cloud LLMs.
- **llama.cpp / whisper.cpp** (`ggml-org`): Metal backends are first-class; whisper.cpp adds a Core ML/ANE encoder path.

## 4. WebGPU

**Spec:** W3C **Candidate Recommendation** (first CR snapshot Dec 2024, continuously maintained; no push to full REC planned). WGSL is the shading language (WebKit's SPIR-V objection shaped this); browsers compile WGSL → MSL/HLSL/SPIR-V via Tint (Dawn), naga (wgpu), or WebKit's own compiler.

**Browser matrix (Aug 2026):**
| Engine | Status |
|---|---|
| Chrome/Edge | Shipped since 113 (2023); **compatibility mode** (GLES3-class hardware) shipped 146 (Feb 2026); Linux rolling out |
| **Safari** | **Shipped 26.0 (Sept 2025)** on macOS/iOS/iPadOS/visionOS — in-house implementation **directly on Metal**, GPU-process isolated; Apple: WebGPU supersedes WebGL. 26.2 added WebXR-on-WebGPU (visionOS); **27 beta adds WGSL `clip_distances`** |
| Firefox | Via wgpu: Windows 141 (Jul 2025), **macOS Apple Silicon 145 (Nov 2025), all Macs 147 (Jan 2026)** |

- **Shipped extensions:** subgroups (Chrome 134), shader-f16; **experimental:** `subgroup_matrix` (cooperative-matrix / tensor-core-style matmul in WGSL — the big browser-ML lever); **proposal:** bindless (blocking mesh shaders; "2026+").
- **Browser ML:** transformers.js **v4** (Mar 2026) rewrote its runtime in C++/WebGPU with the ONNX Runtime team (~4× BERT); onnxruntime-web 1.27 ships a standalone WebGPU EP. **WebNN** is an updated CR (Jan 2026) but still flag-gated — WebGPU is the practical path today.
- **Native use:** **wgpu v30** (Jul 2026; Rust; Metal backend is what Firefox ships) for apps/engines; **Dawn** (C++; `webgpu.h`; emdawnwebgpu is now the recommended Emscripten path) for Chromium-lineage tooling.

## 5. WebAssembly

**Wasm 3.0** (Sept 2025) is the standard: **GC, typed references, tail calls, memory64, relaxed SIMD, multiple memories, exception handling** — all shipped across V8/SpiderMonkey/JavaScriptCore (WasmGC hit Safari 18.2, Dec 2024).

- **JSPI** (suspend wasm on JS Promises without asyncify bloat): Chrome 137+, Firefox 139+, **Safari 27 beta** — universal this fall.
- **Component model / WASI:** WASI 0.2 stable; **WASI 0.3.0 (June 11, 2026)** = native async (`stream<T>`, `future<T>`) in the canonical ABI, supported by Wasmtime 43+ and jco (whose preview3-shim runs WASI 0.3 async *in browsers* via JSPI). **WASI 1.0 + Component Model 1.0 targeted late 2026/early 2027.** Components don't run natively in browsers — jco transpiles.
- **Runtimes:** wasmtime v47 (monthly majors, LTS lines) · wasmer 7.2 (dropped Intel-Mac target!) · wazero 1.12 (pure Go) · **WasmKit 0.3.1** (pure-Swift interpreter, initial component-model support, runs Embedded Swift).
- **Swift→Wasm is official:** Wasm SDKs on swift.org since 6.2 (`wasm32-unknown-wasip1` ± threads), **Embedded Swift for kB-scale wasm**, JavaScriptKit 0.57 (`@JS` macro, generated TypeScript defs) as Swift's wasm-bindgen. Goodnotes ships Swift-in-browser in production.
- **Zig→Wasm:** first-class, lean output, mature. **Emscripten 6.0** (Jun 2026); **wasi-sdk 33** (C++ exceptions default on), 34-rc targets wasip3.
- **JavaScriptCore specifics** (matters for WKWebView + Bun): full Wasm 3.0 by Safari 26; `JSTag` exception bridging (26.0); JS String Builtins (26.2); JSPI (27 beta).

**Concepts:** *Component model vs core wasm* — typed, language-neutral interfaces (WIT "worlds") over linear-memory modules; cross-language composition without shared memory. *WasmGC* — engine-managed heaps for Kotlin/Java/Dart; **Swift deliberately doesn't use it** (ARC + linear memory). *Memory64* — >4 GB but slower (loses guard-page bounds-check elision).

## 6. Swift

**Swift 6.3** (Mar 2026, current): **`@c` attribute** (export Swift to C without Obj-C), first **official Android SDK** (+ swift-java/jextract), module-name selectors, `@specialize`/`@inline(always)`, **prebuilt swift-syntax** (macro clean builds: minutes → seconds), Swift Build engine preview in SPM, FreeBSD preview.
**Swift 6.4** (beta with Xcode 27; GA ~fall 2026): Swift Testing ↔ XCTest interop, async `defer`, fine-grained warnings, 4× faster URL parsing via swift-foundation.

- **Concurrency is now approachable** (6.2): opt-in **default-MainActor isolation** per module, `@concurrent` for explicit offload, `nonisolated(nonsending)`; plus region-based isolation/`sending` (6.0) killed most false positives. Swift 6 mode migration is finally tractable — Xcode templates default to MainActor.
- **Embedded Swift**: matured hard in 6.3 (better linkage model, C interop, debugging; "out of experimental" per WWDC26 coverage — official wording softer). Targets MCUs (Pico/ESP32/STM32), **Wasm**, kernel-adjacent code; used in the Secure Enclave.
- **Interop**: bidirectional C++ interop keeps evolving (dedicated workgroup); `~Copyable`/`~Escapable` + `InlineArray`/`Span` give systems-grade memory control; typed throws (6.0) matter for Embedded.
- **Server**: Hummingbird 2 is the modern structured-concurrency pick; Vapor 4 stable / Vapor 5 alpha (its HTTP server builds on Hummingbird). **swiftly** 1.0 is the official toolchain manager.

## 7. Zig

**0.16.0** (Apr 2026, current): **`std.Io`** — I/O as a passed-in interface like `Allocator` (colorless async): `Io.Threaded` default, experimental `Io.Evented` green-thread loop with **io_uring / kqueue / GCD** backends, `io.async()` → `Future` with `.await()`/`.cancel()`. Type-resolution overhaul, faster incremental builds.
**0.15.1 "Writergate"** (Aug 2025): new buffered Reader/Writer; **self-hosted x86_64 backend default for Debug** (~5× faster debug compiles). **aarch64 self-hosted backend in progress** — Apple Silicon debug builds still go through LLVM. **0.17 imminent**: build-system rework (`zig build --help` 150 ms → 14 ms) + LLVM 22.

- **Ecosystem governance:** Zig migrated **GitHub → Codeberg** (Nov 2025; GitHub is a mirror); Synadia + TigerBeetle pledged **$512K** to the Zig Software Foundation. 1.0: no date, ≥2 breaking releases/year expected.
- **Notable projects:** **Bun** — plot twist: being **rewritten in Rust** (announced May 2026; 1.3.14 possibly the last Zig version). **TigerBeetle** (financial DB, deterministic-sim-tested, ships ReleaseSafe) is the flagship Zig-in-production. **Ghostty 1.3** (Mar 2026) extracted **libghostty** — standalone Zig core + C API with its own release cycle. **ZML** (MLIR-based multi-vendor ML inference). **Mach** engine: alive but experimental, pins nominated Zig versions. Tooling: zls, libxev (Ghostty's event loop), zio (new std.Io-native async framework), zig-clap, zap.
- **`zig cc`**: one binary bundles clang+lld+libcs for dozens of targets — cross-compiling *to* macOS works from anywhere for plain C (`-target aarch64-macos`); linking Apple frameworks needs an SDK sysroot.

## 8. Interop playbook (Mac-specific patterns)

| Pattern | How | Reference |
|---|---|---|
| **Zig core inside a Swift/AppKit app** | `zig build-lib` → static `.a` + C header → SPM/Xcode via modulemap | Ghostty/libghostty; Mitchell Hashimoto's "Integrating Zig and SwiftUI"; `Lakr233/libghostty-spm` |
| Swift exporting a C ABI (no Obj-C) | Swift 6.3 `@c` attribute + `@implementation` | swift.org 6.3 notes |
| Zig calling Metal/AppKit | Obj-C runtime bridges: `mitchellh/zig-objc` (battle-tested), `hexops/mach-objc`, `dmbfm/zig-metal` | Ghostty renderer |
| Zig as cross-compiler for C deps | `zig cc -target aarch64-macos` (+ SDK sysroot for frameworks) | kubkon/zig-ios-example |
| Swift in the browser | Swift Wasm SDK + JavaScriptKit (`@JS`, TS defs) ± Embedded Swift for size | swift.org wasm guide; Goodnotes case study |
| Wasm plugins inside a Swift app | **WasmKit** (pure-Swift runtime, component-model preview) | swiftwasm/WasmKit |
| C++ deps in Swift | Native C++ interop (workgroup-maintained) | swift.org/documentation/cxx-interop |

## 9. Consolidated package index

**Metal/GPU:** metal-cpp (official C++ bindings, now in `apple/game-porting-toolkit`) · MLX + mlx-swift + mlx-lm (`ml-explore/*`) · llama.cpp / whisper.cpp (`ggml-org/*`) · MoltenVK (`KhronosGroup/MoltenVK`) · KosmicKrisp (Mesa/LunarG) · wgpu (`gfx-rs/wgpu`, v30) · Dawn (`google/dawn`) · KTX-Software v5-rc (UASTC HDR).
**Wasm:** wasmtime v47 · WasmKit 0.3.1 · JavaScriptKit 0.57 · jco 1.28 · wit-bindgen 0.60 · wasi-sdk 33 · Emscripten 6.0 · wazero 1.12 · wasmer 7.2.
**Browser ML:** transformers.js v4.2 · onnxruntime-web 1.27 (WebGPU EP).
**Swift:** swift-foundation · swift-testing · swift-collections · swift-async-algorithms · Hummingbird 2 · Vapor 4 · swift-java · mlx-swift.
**Zig:** TigerBeetle · Ghostty/libghostty · ZML · Mach · zls · libxev · zio · zig-clap · zap · zig-objc/mach-objc/zig-metal.

## 10. Watchlist (next 6–12 months)

- **WebGPU bindless** (unblocks mesh shaders on the web) and **subgroup-matrix** stabilization — the two levers for browser-native ML/rendering.
- **Safari 27 GA** (fall 2026): JSPI everywhere; watch `adapter.features` for f16/timestamps/subgroups parity in WebKit; the **Safari MCP server** (agent-driven Safari) is directly relevant to browser tooling.
- **WASI 1.0 + Component Model 1.0** (late 2026/early 2027) — the moment components become a stable plugin ABI.
- **Core AI framework GA** + **Foundation Models open-source drop** (summer 2026) — likely reshuffles the local-LLM stack.
- **M5 Ultra Mac Studio** (~Oct 2026, rumored, up to 768 GB) and **M6/2nm**.
- **Zig 0.17** (build-system rework) and the **aarch64 self-hosted backend** going default — fast Debug builds on Apple Silicon.
- **Swift 6.4 GA** with the OS 27 wave; Embedded Swift's linkage-model completion.
- **Bun-in-Rust** completion — what it means for the Zig ecosystem's flagship roster.

## 11. Hooks for Qwave / 8b-is

- **WebGPU in your engine — verified, with a correction** (see addendum at
  top): NOT inherited by default in `WKWebView`; it is gated behind the
  `_WKFeature` `WebGPUEnabled` + a secure context, both empirically
  confirmed on macOS 26. `FeatureFlagService`'s existing reflection reaches
  the flag today — surfacing it (plus `WebGPUHDREnabled` and
  `WebXRWebGPUBindingsEnabled`) in the FeatureFlags pane is a
  small, concrete follow-up.
- **JSPI (Safari 27)** simplifies any wasm-based extension/plugin runtime you'd embed; **WasmKit** offers a pure-Swift sandbox for running extension wasm outside the page entirely.
- **`MTLTensor` + Neural Accelerators** are a natural substrate for MEM|8-style wave/grid compute (256×256×65536 grids are exactly the shape GPU tensor units like), with MLX as the prototyping layer.
- **libghostty's pattern** (Zig core, C API, Swift shell) is the proven route if 8b-is wants Zig-speed cores under Swift apps — including a future Qwave renderer or a MEM|8 engine.
- **Xcode 27's ACP/MCP agent hooks + Metal's agent-debugging CLI + Safari's MCP server**: Apple is building first-party rails for exactly the agentic dev workflow these kickoff prompts assume.

## Caveats (aggregated, be honest when quoting)

- Several primary domains were egress-blocked during research (apple.com newsroom, webkit.org, w3.org, ziglang.org, developer.chrome.com); those items were verified via search snapshots of the primary URLs and ≥2 secondary sources. Real URLs are cited in the underlying notes.
- Specifically **unverified**: exact M5 Pro/Max bandwidth/core figures; SME2-on-M5; Safari's optional WebGPU feature list (f16/timestamps/subgroups); the Safari version that enabled memory64; exact caniuse %; Zig 0.16 aarch64-backend default status; "Embedded Swift fully out of experimental" (official wording is softer); MLXLanguageModel/Foundation-Models third-party-backend details; MoltenVK star count; mlx-lm latest tag.
- Chrome ~149–150 / Firefox ~152 as current stable versions are cadence estimates, not verified.
- **Verified in this repo** (supersedes the above where they overlap): the
  WKWebView WebGPU gating facts in the addendum — probed 2026-08-13 on the
  Qwave dev machine (macOS 26) with the `responds(to:)`-guarded reflection
  pattern from `FeatureFlags`.
