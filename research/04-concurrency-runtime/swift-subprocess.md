# swift-subprocess (`swiftlang/swift-subprocess`)

| | |
|---|---|
| **Repo** | https://github.com/swiftlang/swift-subprocess |
| **Version** | **1.0.0** — source-stable after a year of public beta |
| **License** | Apache 2.0 |
| **Platforms** | macOS, Linux, Windows, FreeBSD, OpenBSD, Android |
| **Apple Silicon** | Pure Swift over platform process APIs |
| **Verified** | 2026-08-12 |

---

## What it is

The modern replacement for `Foundation.Process`: spawning child processes with an async/await
API, structured concurrency-aware I/O, and cross-platform semantics. Reaching 1.0 marks source
stability after a year of community feedback on the beta.

`Foundation.Process` predates async/await and shows it — callback-based termination handlers,
`Pipe` objects you must drain manually or deadlock on, and no cancellation story that composes
with `Task`.

## Why it matters for Qwave

**Not in the app. Possibly in the build.**

`Qwave.app` should not be spawning subprocesses. A browser that shells out is a browser with a
new and interesting attack surface, and none of Qwave's features need it:

| Plausible use | Why not |
|---------------|---------|
| Launching the VPN tunnel | `NETunnelProviderManager` — no subprocess involved |
| Activating the system extension | `OSSystemExtensionManager` — same |
| Opening a downloaded file | `NSWorkspace.open` — the correct, sandboxed API |
| Anything else | If a browser needs to run a binary, something has gone wrong |

Where it *is* useful is **build-time tooling**, which is real in this repository. The
[SafariConverterLib](../01-webkit-browser-engine/safari-converter-lib.md) note proposes a
`Tools/BlocklistBuilder` executable that fetches filter lists and regenerates
`Shields/Resources/starter-blocklist.json`. That tool orchestrates other processes — `curl`,
`xcodegen`, validation steps — and swift-subprocess is the right way to do it in Swift rather
than in a shell script that nobody tests.

## Apple Silicon notes

No architecture-specific behaviour. Worth noting for build tooling: on Apple Silicon, spawning
an `x86_64` binary through Rosetta is possible but slow, and reproducible builds want
architecture pinned explicitly. All of Qwave's tooling is arm64-native, so this is a non-issue
today — and worth keeping that way.

## Adoption sketch

Only in a build-time package, never in `Packages/QwaveKit`:

```swift
// Tools/BlocklistBuilder/Package.swift
.package(url: "https://github.com/swiftlang/swift-subprocess", from: "1.0.0")
```

```swift
import Subprocess

let result = try await run(
    .path("/usr/bin/curl"),
    arguments: ["-sSL", listURL, "-o", destination],
    output: .string
)
guard result.terminationStatus.isSuccess else { throw BuildError.fetchFailed(result.standardError) }
```

Structured concurrency means cancellation propagates and pipes drain correctly — the two things
`Foundation.Process` makes easy to get wrong.

## Risks

- **Zero value in the shipped app.** Adding it to `Packages/QwaveKit` would be a mistake; keep
  the separation explicit so nobody does it by accident.
- **Shell scripts may be simpler.** For a five-line fetch-and-convert, a `Makefile` or a bash
  script has no dependency and no build step. This earns its place only when the tool grows real
  logic — validation, diffing, rule-count budgeting.
- **New at 1.0.** Source-stable is a commitment, not a track record. Low consequence for build
  tooling.

## Verdict

🟡 **Assess — build tooling only, if and when that tooling exists.**

The right package for its job and unambiguously not a browser dependency. It becomes relevant if
the `Tools/BlocklistBuilder` proposal in category 01 is built and grows past a shell script.

**The rule worth recording:** `Qwave.app` does not spawn subprocesses. If a future feature seems
to need one, that is a design smell to investigate, not a dependency to add.
