# Contributing to Qwave

Thanks for helping make Qwave more inspectable, energy-aware, and useful. Keep
changes focused: every changed line should support the behavior, security
boundary, or documentation being improved.

## Before you start

1. Read [README.md](README.md), [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md),
   and [SECURITY.md](SECURITY.md).
2. Search existing issues and pull requests before starting larger work.
3. For security vulnerabilities, do not open a public issue; follow
   [SECURITY.md](SECURITY.md).

## Local setup

Requirements: macOS 14+, Xcode 16+, Swift 6 language mode, XcodeGen, Go, and
Zig. Generate the project from the repository root:

```sh
xcodegen generate --spec project.yml
```

Never hand-edit `Qwave.xcodeproj`; it is generated from `project.yml`.

## Test and build

Run the package suite first:

```sh
swift test --package-path Packages/QwaveKit -c release
```

Then verify the app target when changing `Sources/`, `project.yml`, entitlements,
or build scripts:

```sh
xcodebuild \
  -project Qwave.xcodeproj \
  -scheme Qwave \
  -configuration Debug \
  -sdk macosx \
  CODE_SIGNING_ALLOWED=NO \
  build
```

VPN activation requires a signed local build with Network Extension entitlements;
see [docs/SIGNING.md](docs/SIGNING.md). A successful unsigned build does not
prove that VPN activation is distributable.

## Swift 6 and concurrency

- Keep QwaveKit targets in Swift 6 language mode with complete strict
  concurrency.
- Prefer actors for mutable service/storage state and `@MainActor` for AppKit,
  SwiftUI, and WebKit-facing state.
- Model cross-boundary data as `Sendable` structs/enums. Do not pass SQLite
  handles, WebKit objects, or UI controllers between actors.
- Use native async APIs instead of adding continuations around APIs that already
  support `async`/`await`.
- Treat `@unchecked Sendable` as an audited compatibility boundary, not a
  compiler escape hatch. Document why it is safe and keep its scope minimal.

## Network and security changes

If a change creates or changes an app-owned network request:

1. Update `Packages/QwaveKit/Sources/QwaveSupport/EgressAllowlist.swift` only
   when the host is justified.
2. Add or update `EgressGuardTests`.
3. Document the endpoint, trigger, opt-in state, and data sent in
   [docs/NETWORK.md](docs/NETWORK.md).
4. Re-check the threat model and [SECURITY.md](SECURITY.md).

Crypto changes require independent test vectors and an update to
[docs/CRYPTO_REVIEW.md](docs/CRYPTO_REVIEW.md). Do not introduce new crypto
primitives or silently change downgrade behavior.

## Pull requests

A good pull request is small enough to review and includes:

- a clear problem statement and scope;
- tests for new behavior and regressions;
- documentation for user-visible, security, network, or build changes;
- generated-project changes only through `project.yml`;
- a note describing commands run and any environment-specific limitation.

Before requesting review:

```sh
git diff --check
swift test --package-path Packages/QwaveKit -c release
```

Use imperative commit messages, avoid unrelated formatting churn, and never
commit credentials, signing keys, generated Xcode projects, or local build
artifacts.

## Documentation and visual assets

The public docs site lives in `docs/`. Keep its dark/aqua visual language,
provide descriptive `alt` text, and optimize large raster assets before adding
them. Architecture diagrams should prefer deterministic SVG/HTML when they
communicate structure; generated raster art is for editorial hero/gallery use.
