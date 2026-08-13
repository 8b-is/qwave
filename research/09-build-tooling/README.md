# 09 · Build & Tooling

| Tool | Version | Verdict | Role in Qwave |
|------|---------|---------|---------------|
| [XcodeGen](xcodegen.md) | 2.46.0 | 🟢 Adopt (already in) | `project.yml` → `Qwave.xcodeproj` |
| [swift-format](swift-format.md) | 603.0.0 | 🟢 Adopt | Formatting in CI |
| [Periphery](periphery.md) | 3.8.0 | 🔵 Trial | Dead code detection |
| [SwiftLint](swiftlint.md) | 0.65.0 | 🟡 Assess | Lint rules beyond formatting |
| [Tuist](tuist.md) | 1.256.4 | 🟡 Assess | XcodeGen alternative |
| [swift-build](swift-build.md) | Swift 6.3.1 | 🔴 Hold | Not a project-level dependency |

---

## What Qwave already has right

`AGENTS.md` §1 states it plainly: **zero Xcode hand-edits**. `project.yml` is the single source
of truth, `Qwave.xcodeproj` is gitignored, and every project change goes through
`xcodegen generate`.

That discipline is worth more than any tool in this category. It eliminates project file merge
conflicts, makes the build configuration reviewable in a diff, and means a fresh clone builds
identically to CI.

The remaining gaps are quality gates, not build mechanics.

## The gaps

| Gap | Answer |
|-----|--------|
| No formatting enforcement | [swift-format](swift-format.md) — Apple-maintained, matches the Swift style guide |
| No dead code detection | [Periphery](periphery.md) — and 0.1.0 shipped a lot of code fast |
| No lint rules beyond format | [SwiftLint](swiftlint.md) — overlaps swift-format; adopt second if at all |

Order matters. Add swift-format first: it is uncontroversial, it is Apple's, and it settles the
formatting arguments that otherwise contaminate lint discussions.

## On replacing XcodeGen

[Tuist](tuist.md) is the credible alternative, and its differentiator is **build caching**.
That is compelling for a 50-module app with a large team. Qwave is 6 modules and a small
codebase, where a clean build is already fast.

**Do not migrate.** XcodeGen 2.46 added package traits support for remote and local package
references — which is the feature the [MLX Swift](../02-on-device-ai/mlx-swift.md) trait-gating
proposal needs. XcodeGen is keeping current with the platform and doing the job.

## The CI shape

`.github/workflows/ci.yml` and `release.yml` exist. The quality gates worth adding, in order:

```
swift test --package-path Packages/QwaveKit     # exists
swift-format lint --strict --recursive Sources Packages   # add first
periphery scan                                   # add second (report-only at first)
xcodegen generate && xcodebuild ...              # exists
```

Periphery should start as report-only. A dead-code scanner that fails the build on day one just
gets disabled.
