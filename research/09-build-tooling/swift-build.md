# swift-build (`swiftlang/swift-build`)

| | |
|---|---|
| **Repo** | https://github.com/swiftlang/swift-build |
| **Version** | **Swift 6.3.1 Release** (Apr 24) — versioned with the toolchain |
| **License** | Apache 2.0 |
| **Platforms** | macOS, Linux, Windows |
| **Apple Silicon** | Native |
| **Verified** | 2026-08-12 |

---

## What it is

The open-sourced build engine underlying Xcode's build system, contributed to the Swift project
so that SwiftPM and Xcode can share one build engine across platforms. It handles task
scheduling, dependency graph construction, and incremental build correctness.

This is the layer *beneath* `swift build` and Xcode — not a tool you invoke or a package you
depend on.

## Why it matters for Qwave

**Indirectly. It is infrastructure, not a dependency**, and this note exists to make that
distinction explicit rather than to evaluate an adoption.

What it means in practice:

- **Consistency across surfaces.** `swift test --package-path Packages/QwaveKit` and
  `xcodebuild -scheme Qwave` converge on the same engine, so build behaviour that differs between
  SwiftPM and Xcode becomes less likely over time. Qwave uses both — `AGENTS.md` §2 for SPM
  tests, `xcodebuild` for the app — so this is a real, if slow-moving, benefit.
- **Incremental build correctness.** Improvements land in the toolchain and arrive with an Xcode
  update. Nothing to adopt.
- **Visibility.** When a build behaves strangely, the engine is now readable source rather than a
  closed box. That is genuinely useful for a rare hard debugging session.

That is the whole story. There is no version to pin, no dependency to add, and no configuration
to write.

## Apple Silicon notes

Native, and it schedules across performance and efficiency cores. For a project Qwave's size the
practical effect is invisible.

The Apple Silicon-relevant build fact worth recording is elsewhere: **Xcode 27 is Apple
Silicon-only and requires macOS 26.4+ to run**, which is a CI runner requirement if Qwave adopts
that toolchain.

## Adoption sketch

None. It arrives with the toolchain.

The actionable adjacent item is **pinning the toolchain in CI**, so build behaviour does not
change under the project silently:

```yaml
# .github/workflows/ci.yml
- uses: maxim-lobanov/setup-xcode@v1
  with:
    xcode-version: '26.x'    # pin explicitly; do not track 'latest'
```

Tracking `latest` means a new Xcode release can change build behaviour, formatter output (see
[swift-format](swift-format.md)'s toolchain coupling), and Swift language mode defaults —
without a commit.

## Risks

Not applicable as a dependency. The associated risk is **unpinned toolchains in CI**, which is a
real and common problem and is addressed by the snippet above.

## Verdict

🔴 **Hold — not a project-level dependency.**

Important infrastructure, correctly invisible. Recorded so that "swift-build is open source now,
should we use it?" resolves immediately: it is the engine under the tools Qwave already uses, and
there is nothing to adopt.

**The actionable item from this note:** pin the Xcode version in CI. That is where toolchain
changes actually reach the project.
