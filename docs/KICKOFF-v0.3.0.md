# Qwave v0.3.0 — Kickoff Handoff (Ultracode Mode)

> Handoff prompt for the next agent (Claude Opus). Treat every item as a
> complete, end-to-end task: implement, wire, test, verify. No partial
> deliveries. No TODOs left behind. Commit each milestone as it lands.

## Mission

Deliver **Qwave v0.3.0**: turn the unsigned demonstration build into a
**signed, notarised, auto-updating browser**, close the **host-identity
shielding bypass**, and harden the engineering loop (logging, tests,
blocklist scale-up) — then tag and publish.

**Repository:** `https://github.com/peterlodri-sec/qwave` (`main`)

## Current state (verified at handoff)

- `main` @ `5049f9f` (v0.2.0 feature commit `f824610` + research tree
  `5049f9f`), tag `v0.2.0` pushed, working tree clean.
- **150/150 SPM tests green**: `swift test --package-path Packages/QwaveKit`.
- **Release unsigned build green**:
  `xcodebuild -project Qwave.xcodeproj -scheme Qwave -configuration Release -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY= build`.
- Modules: `BrowserCore`, `Shields`, `FeatureFlags`, `VPNKit`,
  `PostQuantum` (Keccak/ML-KEM-768/McEliece-348864/`HybridKEM`),
  `WebExtensions`, `Persistence`, `QwaveSupport` + vendored `WireGuardKit`.
- `research/` contains 41 evaluated packages; read
  [research/README.md](../research/README.md) first — the roadmap below is
  driven by its four findings.

## Priority backlog (do in order)

### P0-1 — Code signing + notarisation + Sparkle
The highest-leverage work: the *same* fix unblocks the VPN system extension,
Stage B end-to-end, and auto-updates. See [docs/SIGNING.md](SIGNING.md),
`project.yml` (entitlements already declared via `$(TeamIdentifierPrefix)`),
`.github/workflows/release.yml`, and
[research/distribution/sparkle.md](../research/distribution/sparkle.md).
- Wire Sparkle 2.9.5 (verified 2026-08-12) into the app: `SUFeedURL` appcast
  on GitHub Releases, EdDSA update signatures, `generate_appcast` in CI.
- Harden `release.yml`: Developer ID signing, notarisation
  (`notarytool`), staple, DMG via `create-dmg`.
- Keep the unsigned build path working for local dev (DoD step below must
  still pass with `CODE_SIGNING_ALLOWED=NO`).
- **Verify:** signed build passes `spctl -a -vv`, extension installs and
  connects (or documents the exact dev-environment gap).

### P0-2 — Host-identity shielding bypass (`WebURL`)
Foundation `URL.host` and WebKit disagree on IDN/confusable hosts,
backslashes, and `user@evil@good` authorities — `ShieldsPolicy` can shield a
page under one identity while WebKit loads another. That is a bypass class.
- Adopt `WebURL` 0.4.2 (verified 2026-08-12, Apache-2.0) as the canonical
  host/URL identity source.
- Touch points: `Shields.ShieldsPolicy.resolvedPolicy(forHost:)`,
  `BrowserCore.OmniboxParser`, container key derivation in
  `ContainerRegistry`.
- **Verify:** table-driven tests for confusable/IDN/backslash/`@` cases; all
  150 existing tests stay green.

### P1-1 — Structured logging (`swift-log`)
- Wrap `QwaveSupport.QwaveLog` around `swift-log` 1.6.x with an `os_log`
  backend; keep the existing category API so call sites don't churn.
- **Verify:** privacy redaction — browser URLs must stay `.private`; a test
  asserts the redacted path.

### P1-2 — Blocklist scale-up (SafariConverterLib, license-gated)
- The 51-rule starter list is a demonstration. Evaluate WebKit's
  `SafariConverterLib` as a **build-time** tool: list text → compiled
  content-blocker bytecode bundled as a resource, replacing the starter list
  with a compiled EasyList snapshot.
- **Hard gate:** confirm the copyleft status of the exact files used before
  writing code. If it fails the gate, fall back to growing the bundled list
  via the existing `UBORuleListCompiler` + `RemoteBlocklistUpdater` pipeline.
- **Verify:** shipped list compiles through `WKContentRuleListStore` in CI
  (see `ShieldsTests/RuleListCompileTests` for the pattern).

### P1-3 — Test & bench upgrades
- New tests in `swift-testing` (bundled with the toolchain) — start with the
  PostQuantum KAT vector loops and Shields parser cases.
- Add `swift-snapshot-testing` goldens for `UBORuleListCompiler` JSON output.
- **Do NOT** try to benchmark hibernation memory reclaim with
  package-benchmark — that memory lives in WebKit's out-of-process content
  processes; design a separate measurement plan (Activity Monitor / `footprint`
  sampling) and document it in `docs/ENERGY.md`.

### P2 — Research-driven backlog
Anything else from `research/README.md` (MLX trial behind feature flags,
Pulse debug console for VPN traffic, `swift-format` in CI, GRDB migration for
`Persistence`) — pick up only after P0/P1 land.

## Landmine rules (field data from v0.1.0 + v0.2.0)

1. **XcodeGen spec first** — never hand-edit `.xcodeproj`; change
   `project.yml`, run `xcodegen generate --spec project.yml`.
2. **MainActor isolation** — `@MainActor` classes must not use main
   actor-isolated initializers in default arguments (`init(tunnel:
   TunnelManager? = nil)`, never `= TunnelManager()`).
3. **SPM discipline** — commands via
   `swift test --package-path Packages/QwaveKit`; `WireGuardKitC` headers
   need `#include <sys/types.h>` before BSD types.
4. **WebKit SPI safety** — `FeatureFlagService` guards every ObjC reflection
   with `responds(to:)` (class + instance selectors).
5. **Crypto gotchas (learned the hard way)** — ML-KEM INTT scales by
   128⁻¹ = 3303 (not 256⁻¹); NTT-domain products use basemul, not pointwise;
   McEliece error bits are **XORed** into the codeword (never ORed); RREF
   pivot rows must preserve insertion order (list, not set); GF polynomial
   division must return `[0]` (never `[]`) for exact division.
6. **VPN routing guarantee** — all app-level HTTP stays on `URLSession`
   (follows the system routing table → through the tunnel). Never introduce
   raw-socket clients (SwiftNIO et al.) — see
   `research/networking/swift-nio.md`.

## Definition of Done (every milestone)

```bash
# 1. All SPM tests green
swift test --package-path Packages/QwaveKit
# 2. Regenerate the project
xcodegen generate --spec project.yml
# 3. Release build (unsigned path still works)
xcodebuild -project Qwave.xcodeproj -scheme Qwave -configuration Release \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY= \
  build | xcbeautify
# 4. Tag & publish
git tag v0.3.0 && git push origin v0.3.0
```

## Ultracode contract

- Break nothing: the 150-test suite is the floor.
- Prefer surgical diffs over rewrites; match existing module patterns.
- When blocked, try at least two distinct approaches before stopping.
- End every response by continuing to the next unfinished task — a reply is
  not "done" until the tag is pushed.
