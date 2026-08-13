# mlx-swift-examples (`ml-explore/mlx-swift-examples`)

| | |
|---|---|
| **Repo** | https://github.com/ml-explore/mlx-swift-examples |
| **Version** | **2.29.1** — tracks [MLX Swift](mlx-swift.md) releases |
| **License** | MIT |
| **Platforms** | macOS, iOS — Apple Silicon only |
| **Apple Silicon** | Inherited from MLX Swift |
| **Verified** | 2026-08-12 |

---

## What it is

Apple's companion repository to MLX Swift: runnable example applications and, more usefully,
**model implementations** — the Swift ports of the transformer architectures MLX can run. The
2.29.1 release included a port of nanochat and support for Qwen 3 VL dense models, which is
representative of what the repo actually is: architecture support tracking upstream model
releases.

The version scheme mirrors the MLX Swift release it targets, so `2.29.x` corresponds to
mlx-swift `0.29.x`.

## Why it matters for Qwave

**As reference material, not as a dependency.**

If Qwave ever runs a local model through MLX, someone has to answer: how do you load weights,
apply the tokeniser, manage the KV cache, and stream tokens back to a SwiftUI view without
blocking? This repository answers all four with code Apple maintains.

The specific pieces worth reading before writing any MLX integration:

| Concern | Why the examples matter |
|---------|------------------------|
| Model loading | Weight loading and quantisation handling is fiddly and easy to get subtly wrong |
| Tokenisation | Shows the [swift-transformers](swift-transformers.md) integration in practice |
| KV cache | Determines whether multi-turn interaction is fast or quadratic |
| Token streaming | Async streaming into SwiftUI without stalling the main actor |
| Memory limits | `MLX.GPU.set(cacheLimit:)` and friends — directly relevant to coexisting with WebKit |

That last row is the one that matters most for a browser. Coexisting with WebKit content
processes means capping MLX's GPU cache explicitly, and the examples show where those knobs are.

## Apple Silicon notes

Nothing beyond what [MLX Swift](mlx-swift.md) provides. The examples are the practical
demonstration that a 4-bit quantised 7B model runs comfortably in unified memory on an M-series
laptop — the claim that makes the whole category plausible for a desktop app.

## Adoption sketch

Do not add it to `Package.swift`. It is an examples repository: the dependency surface is large,
the API is not stability-guaranteed, and most of it is application code you do not want.

Instead, vendor the specific model implementation you need:

```
Packages/QwaveKit/Sources/Assist/Models/
  Qwen3.swift        # adapted from mlx-swift-examples, with provenance comment + MIT notice
```

```swift
// Provenance header — MIT requires attribution, and future readers need the lineage
// Adapted from ml-explore/mlx-swift-examples @ 2.29.1 — MIT License.
// Upstream: https://github.com/ml-explore/mlx-swift-examples
```

If a whole family of architectures is needed, depending on the `MLXLLM` product directly is
defensible — but at that point you have taken on a large, fast-moving surface, and the
[Foundation Models](foundation-models.md) path deserves another look.

## Risks

- **Not an API-stable library.** It is examples. Minor releases restructure things freely.
- **Broad dependency surface.** Pulls in tokenisers, Hub download machinery, and sample app
  scaffolding — most of which a browser does not want.
- **Vendoring means maintaining.** A copied model implementation does not receive upstream fixes.
  Record the exact source version and re-check periodically.
- **Tracks MLX Swift's cadence.** Both move every few weeks. Version drift between the two is a
  real source of build breakage.

## Verdict

🟡 **Assess — read it, borrow from it, do not depend on it.**

This is the reference implementation for everything hard about MLX integration, and it is
Apple-maintained. It is also explicitly an examples repository, which makes it the wrong shape
for a dependency in a browser that treats every transitive dependency as attack surface.

Relevant only if [MLX Swift](mlx-swift.md) advances past Trial. Under the recommended sequence —
Foundation Models first — that may never happen, which is a good outcome.
