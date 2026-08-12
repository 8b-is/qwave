# Tuist (`tuist/tuist`)

| | |
|---|---|
| **Repo** | https://github.com/tuist/tuist |
| **Version** | **1.256.4** (Aug 12) — server component; releases are near-daily |
| **License** | MIT |
| **Apple Silicon** | Native |
| **Verified** | 2026-08-12 |

---

## What it is

A project generation and developer-productivity toolchain for Xcode projects. Where
[XcodeGen](xcodegen.md) generates a project from YAML, Tuist generates it from **Swift** — giving
type safety and the ability to put logic in the project definition.

It is also substantially more than a generator:

- **Build caching**, local and remote — pre-compiled target artifacts reused across builds.
- **Project scaffolding** for consistent module creation.
- **Modularisation support** with dependency graph analysis.
- **A server component**, which is what the 1.256.x version stream tracks.

The caching is the headline. It is the biggest single difference from XcodeGen.

## Why it matters for Qwave

**As the alternative that was evaluated and rejected** — worth recording, because "should we use
Tuist?" recurs in any project using XcodeGen.

### The caching argument does not apply at this scale

Tuist's value proposition is compile time. That value scales with module count and codebase
size — a 50-module app with a large team saves hours per day.

Qwave is **6 modules and roughly 40 source files**. A clean build is already fast on Apple
Silicon, and incremental builds are faster still. Cache infrastructure would cost more to
maintain than the seconds it saves.

### Swift configuration versus YAML

Tuist's typed Swift manifests are a genuine advantage — for large specs. Qwave's `project.yml`
is **4 KB**. YAML is the right tool at that size; the type safety solves a problem a 4 KB file
does not have.

### XcodeGen is keeping current

The 2.46.0 release added **Swift package traits support** for remote and local package
references — which is exactly what the [MLX Swift](../02-on-device-ai/mlx-swift.md) trait-gating
proposal in this research needs. XcodeGen is not falling behind the platform.

### Migration cost is not zero

`AGENTS.md` §1 and §2 codify the XcodeGen workflow, CI depends on it, and `docs/SIGNING.md`
documents the signing path through the generated project. Migration means rewriting all of that
to buy caching for a project that does not need it.

## Apple Silicon notes

Native, and its caching is well-suited to Apple Silicon build machines. Not a differentiator at
Qwave's scale.

Worth noting for either tool: **Xcode 27 is Apple Silicon-only and requires macOS 26.4+**, so CI
runner requirements are a toolchain question, not a generator question.

## Adoption sketch

Not recommended. For completeness, the shape:

```swift
// Project.swift — Tuist's equivalent of project.yml
import ProjectDescription

let project = Project(
    name: "Qwave",
    targets: [
        .target(name: "Qwave", destinations: .macOS, product: .app, /* ... */),
        .target(name: "PacketTunnel", destinations: .macOS, product: .systemExtension, /* ... */),
    ]
)
```

## Risks

- **Migration cost with no matching benefit** at 6 modules.
- **Larger tool surface.** A server component, a cache backend, an account model. XcodeGen is one
  binary that emits one file.
- **Near-daily releases.** Active development is good; it also means more version churn in a core
  build dependency.
- **Ecosystem lock-in.** Tuist's scaffolding and caching create workflow dependencies that are
  harder to unwind than a YAML file.

## Verdict

🟡 **Assess — the right tool for a different project.**

Tuist is excellent, and its caching genuinely transforms large modular codebases. Qwave is not
one: 6 modules, 4 KB of project spec, fast clean builds.

**Stay on [XcodeGen](xcodegen.md).** Its 2.46 traits support covers the one forward-looking need
identified anywhere in this research folder, and the zero-hand-edits discipline in `AGENTS.md`
already delivers the property that matters most — reproducible, reviewable project configuration.

**Revisit if** Qwave grows past roughly 15–20 modules, or if clean build times become a real
bottleneck for CI or contributors. Neither is close.
