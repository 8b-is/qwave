# swift-transformers (`huggingface/swift-transformers`)

| | |
|---|---|
| **Repo** | https://github.com/huggingface/swift-transformers |
| **Version** | **1.3.3** (May 16) |
| **License** | Apache 2.0 |
| **Platforms** | macOS, iOS |
| **Apple Silicon** | Pure Swift; pairs with Core ML and MLX pipelines |
| **Verified** | 2026-08-12 |

---

## What it is

Hugging Face's Swift package for the **glue around** on-device inference, rather than inference
itself. Three pieces matter:

- **`Tokenizers`** — Swift implementations of the tokeniser families (BPE, Unigram, WordPiece)
  that load directly from a model's `tokenizer.json`. The 1.3.3 release was tokenisation
  correctness work, including a BERT NFD decomposition fix — representative of what this package
  spends its time on.
- **`Hub`** — downloading and caching model repositories from the Hugging Face Hub.
- **`Generation`** — sampling loops (greedy, top-k, top-p) over a model backend.

Tokenisation is the part people underestimate. Getting it subtly wrong produces output that
looks plausible and is quietly degraded — no crash, no error, just worse results.

## Why it matters for Qwave

Only in the [MLX Swift](mlx-swift.md) branch of the decision tree. MLX gives you tensors and
graph execution; it does not give you a tokeniser matching the model's training-time
vocabulary. Something has to, and hand-rolling BPE against a `tokenizer.json` is a bad use of
engineering time and a good source of silent bugs.

Under the [Foundation Models](foundation-models.md) path, **this package is irrelevant** — Apple
handles tokenisation entirely inside the framework. That is one more reason the Foundation
Models path is cheaper than it first appears: it eliminates this whole layer.

The `Hub` component is separately interesting and separately problematic. It solves model
distribution, which is the largest unsolved piece of the MLX path — and it solves it by making
the browser download from a third-party service at runtime, which cuts against Qwave's
sovereignty stance. If `Hub` is ever used, it must be an explicit, user-initiated, clearly
disclosed download, not an implicit fetch.

## Apple Silicon notes

Pure Swift, no architecture-specific code. Tokenisation is CPU-bound and single-threaded, and
it is not the bottleneck — prefill and decode dominate. On M-series the efficiency cores handle
tokenisation comfortably while the GPU runs inference, which is the right division.

## Adoption sketch

```swift
// Only inside an MLX-backed optional module
.package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.3")
```

```swift
import Tokenizers

let tokenizer = try await AutoTokenizer.from(pretrained: "Qwen/Qwen3-1.7B")
let ids = tokenizer.encode(text: prompt)
```

If `Hub` is used at all, wrap it so the download is explicit and cancellable, and so the model
cache location is visible to the user in the Settings window alongside the other storage
Qwave manages.

## Risks

- **Runtime network dependency (via `Hub`).** A sovereign browser fetching from a third-party
  service needs this to be a deliberate, disclosed, user-initiated action. Prefer bundling or a
  self-hosted mirror if the MLX path ever ships.
- **Tokeniser/model version coupling.** The tokeniser must match the model exactly. Mismatches
  degrade output silently.
- **Only relevant in one branch.** Zero value under the recommended Foundation Models sequence.
- **Third-party dependency in the trust boundary.** Every dependency in a browser is attack
  surface. Apache 2.0 and a reputable maintainer help; they do not eliminate the audit burden.

## Verdict

🟡 **Assess — conditional on the MLX path, which is itself conditional.**

Well-built, correctly scoped, and the right answer if you are running models through MLX. But it
sits two decision levels down: it only matters if MLX advances past Trial, which only happens if
Foundation Models proves insufficient.

If it is ever adopted, use `Tokenizers` and think hard about `Hub` — the tokeniser is pure local
computation, while the Hub client is a runtime network dependency with a different risk profile
entirely.
