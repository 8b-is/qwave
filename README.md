# Qwave — a browser that proves what it sends

[![Qwave CI](https://github.com/8b-is/qwave/actions/workflows/ci.yml/badge.svg)](https://github.com/8b-is/qwave/actions/workflows/ci.yml)
[![Platform](https://img.shields.io/badge/macOS-14%2B-black?style=flat-square&logo=apple)](https://apple.com)
[![Swift](https://img.shields.io/badge/Swift-6-orange?style=flat-square&logo=swift)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg?style=flat-square)](LICENSE)

![Qwave hero](docs/assets/hero-v2.jpg)

Qwave is an open-source, WebKit-native macOS browser for people who want
stronger boundaries around browsing data without giving up the system engine.
It combines per-container storage universes, native content shields, tab
hibernation, an optional Mullvad WireGuard tunnel, a post-quantum negotiation
path, and an egress allowlist that makes Qwave's own network activity auditable.

> Qwave is privacy-oriented software, not a promise of anonymity. Read the
> [threat model](SECURITY.md) and the [network inventory](docs/NETWORK.md).

## What makes it different

- **Container universes** — each profile gets its own WebKit data store;
  ephemeral tabs use non-persistent storage and are never restored.
- **Native shields** — a compiled EasyList/uBlock rule set, per-host JavaScript
  controls, and HTTPS-First operate at WebKit policy boundaries.
- **Energy-aware tabs** — background WebKit views can be hibernated while tab
  state, history, and scroll position remain restorable.
- **Optional VPN** — Mullvad relay discovery and WireGuard live in a dedicated
  Network Extension; quantum-resistant PSK negotiation fails closed when enabled.
- **MemoryWave** — container-scoped encrypted memory storage with opt-in,
  AI-agnostic inference providers. Stored memories do not leave the Mac unless
  you explicitly configure a remote provider.
- **WebExtensions MV3** — a focused `browser.*` bridge for tabs, storage, and
  runtime messaging without embedding a second browser engine.

## Architecture at a glance

```text
Qwave.app                         AppKit shell + SwiftUI settings
├── QwaveKit                      local Swift package, Swift 6 language mode
│   ├── BrowserCore                tabs, containers, navigation, hibernation
│   ├── Shields                    content rules and HTTPS-First
│   ├── Persistence                actor-isolated SQLite stores
│   ├── MemoryWave                 encrypted MEM8 memory substrate
│   ├── VPNKit                     Mullvad API, tunnel lifecycle, PQ seam
│   ├── PostQuantum                 Keccak, ML-KEM, Classic McEliece, hybrid KEM
│   ├── WebExtensions               MV3 registry and browser.* bridge
│   ├── URLIdentity                 WHATWG/WebKit-compatible host identity
│   ├── FeatureFlags                guarded WebKit SPI feature access
│   └── QwaveSupport                logging, keychain, egress guard
└── PacketTunnel.systemextension    WireGuardKit + NetworkExtension boundary
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for dependency direction,
isolation rules, data flow, and test boundaries.

## Build locally

### Requirements

- macOS 14 or newer
- Xcode 16+ (the package uses Swift 6 language mode)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Go and Zig for the packet-tunnel pre-build steps

### Package tests

```sh
swift test --package-path Packages/QwaveKit -c release
```

### Generate and build the app

```sh
xcodegen generate --spec project.yml
xcodebuild \
  -project Qwave.xcodeproj \
  -scheme Qwave \
  -configuration Release \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY= \
  build
```

`project.yml` is the source of truth. Never hand-edit the generated
`Qwave.xcodeproj`. VPN activation requires the signing and entitlement setup in
[docs/SIGNING.md](docs/SIGNING.md).

## Swift 6 engineering rules

- QwaveKit targets use Swift 6 language mode and complete strict concurrency.
- Persistence, MemoryWave, and service state use actors or explicit main-actor
  ownership; cross-boundary values are `Sendable` value types.
- The NetworkExtension provider is a narrow SDK compatibility boundary. Its
  legacy mutable provider surface is documented in [SECURITY.md](SECURITY.md)
  and must not leak into QwaveKit APIs.
- Async WebKit and persistence APIs stay async at their boundary; do not add
  blocking queues or semaphore bridges to silence compiler diagnostics.
- New network clients must update the committed egress allowlist and tests.

## Repository map

```text
Packages/QwaveKit/       Swift package and headless tests
Packages/WireGuardKit/   vendored WireGuard bridge
Sources/QwaveApp/        AppKit shell and SwiftUI panes
Sources/PacketTunnel/    Network Extension provider
Resources/               plists, entitlements, bundled rules
docs/                    architecture, network, signing, design site
research/                evaluated platform/package notes
project.yml              XcodeGen source of truth
```

## Documentation

- [Architecture](docs/ARCHITECTURE.md)
- [Security policy and threat model](SECURITY.md)
- [What Qwave sends](docs/NETWORK.md)
- [VPN Stage B](docs/VPN_STAGE_B.md)
- [Signing and activation](docs/SIGNING.md)
- [Blocklist pipeline](docs/BLOCKLIST.md)
- [Energy measurement](docs/ENERGY.md)
- [Crypto review](docs/CRYPTO_REVIEW.md)
- [Contributing](CONTRIBUTING.md)
- [Project gallery](https://8b-is.github.io/qwave/)

## Status

The browser core, shields, WebExtensions MV3 bridge, MemoryWave, post-quantum
KEM implementation, signed release workflow, and Swift 6 concurrency migration
are implemented and covered by package tests. The VPN system extension still
depends on Apple Network Extension entitlements for signed distribution; see
[docs/SIGNING.md](docs/SIGNING.md) for the exact gap.

## License

Qwave is released under the [MIT License](LICENSE). Copyright © 2026 8b.is /
Peter Lodri.
