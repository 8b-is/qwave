# Periphery (`peripheryapp/periphery`)

| | |
|---|---|
| **Repo** | https://github.com/peripheryapp/periphery |
| **Version** | **3.8.0** (Jul 25) |
| **License** | MIT |
| **Install** | `brew install periphery` |
| **Apple Silicon** | Native |
| **Verified** | 2026-08-12 |

---

## What it is

A dead code detector for Swift. Periphery builds an index of the project and reports declarations
that are never referenced: unused types, functions, properties, protocol conformances, and
enum cases.

The 3.8.0 release added retention options for properties on `Equatable` and `Hashable` types,
which is characteristic of the tool's real engineering problem — Swift has many ways a
declaration can be used without an obvious call site, and the value of the tool is entirely in
how well it handles them.

## Why it matters for Qwave

The v0.1.0 release shipped a **lot** of surface area at once: 6 modules, ~40 source files, VPN
integration, shields, feature flags, and persistence. `CHANGELOG.md` describes seven major
subsystems in a single release.

Code written that fast reliably contains scaffolding that never got wired up — a
`DownloadManager` method the UI never calls, a `MullvadModels` field nothing decodes, a
`FeatureFlagSafety` helper superseded during development. That is not a criticism of the release;
it is what shipping a large v0.1.0 looks like.

For a **sovereign browser** there is a sharper argument. Unused code in a security-sensitive
codebase is a liability:

- It is reviewed less carefully, because it appears inert.
- It can be reached by reflection or by a future change that assumes it was maintained.
- It inflates the audit surface for anyone verifying the sovereignty claims.

`VPNKit` and `Shields` are where this matters most, and both are prime candidates for
accumulated scaffolding.

## Apple Silicon notes

Native and fast. Periphery drives a build to produce its index, so scan time tracks build time —
which on Apple Silicon is comfortable for a project this size.

## Adoption sketch

```bash
brew install periphery
periphery scan --project Qwave.xcodeproj --schemes Qwave --targets Qwave,QwaveKit
```

Configure via `.periphery.yml`:

```yaml
project: Qwave.xcodeproj
schemes: [Qwave]
targets: [Qwave, QwaveKit]
retain_public: true          # QwaveKit is a library; public API is intentionally unused internally
retain_objc_accessible: true # AppKit/WebKit reach code through the Objective-C runtime
```

Both retention options are load-bearing here. `QwaveKit` is a library whose `public` API is
consumed by the app target, and Qwave's `FeatureFlags` module deliberately uses `responds(to:)`
reflection against `_WKFeature` — code that a static analyser cannot see being used.

**Start report-only in CI:**

```yaml
- name: Dead code scan (report only)
  run: periphery scan --format github-actions || true
```

A dead-code scanner that fails the build on day one gets disabled on day two. Let it report for a
few weeks, work the list down, then make it blocking.

## Risks

- **False positives are the main cost.** Reflection, `@objc` dynamic dispatch, `Codable` synthesis,
  and SwiftUI's property wrappers all create usage a static analyser can miss. Qwave's SPI
  reflection in `FeatureFlags` is precisely this pattern. Configure retention carefully and treat
  results as a list to triage, not a list to delete.
- **`retain_public` blunts the tool.** With it on, unused `public` API inside `QwaveKit` goes
  unreported — which is most of the module's surface. Consider periodic scans with it off,
  reviewed by hand.
- **Requires a full build.** Adds real time to CI. Nightly rather than per-PR is a reasonable
  compromise.
- **Deleting code has risk.** Every removal is a change. Delete in small reviewed batches with
  tests green, not in one sweep.

## Verdict

🔵 **Trial — report-only first, blocking later.**

A large, fast v0.1.0 is exactly the situation Periphery is built for, and unused code in a
security-sensitive browser is a real liability rather than a tidiness concern.

Held at Trial because the false-positive story needs tuning against Qwave's specific patterns —
particularly the `_WKFeature` reflection in `FeatureFlags`, which is exactly the shape of code
this tool struggles with.

**Sequence:** run it locally once, triage the output by hand, tune `.periphery.yml` until the
signal is good, and only then add it to CI as report-only.
