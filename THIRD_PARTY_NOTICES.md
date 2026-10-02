# Third-Party Notices

Qwave is MIT-licensed (see [LICENSE](LICENSE)). The components below ship in
Qwave's binary or build and carry their own licenses. This file is the
attribution record; each project's full license text lives at the linked
location and takes precedence over this summary.

## The sovereign core (`core/`)

| Component | License | Notes |
|---|---|---|
| qwave-core (this repository) | MIT | egress, mem8 waves, Phoenix, telemetry |
| [mem-16-10](https://github.com/peterlodri-sec/mem-16-10) | AGPL-3.0-only | Linked **only** in the nightly channel (`--features nightly`); the stable build does not link it and keeps Qwave's MIT posture |

## Vendored data

| Component | License | Notes |
|---|---|---|
| [Mozilla Public Suffix List](https://publicsuffix.org/list/public_suffix_list.dat) | MPL-2.0 | ICANN section vendored in `Packages/QwaveKit/Sources/WebCredentials/PublicSuffixData.swift` (snapshot 2026-10-01_23-02-52_UTC, commit `6cd82af`); the data file is not modified, only filtered to the ICANN rules and punycode-normalised |
| EasyList / uBlock Origin filter lists | GPL-3.0 / GPLv3-licensed lists | Compiled into `WKContentRuleList` at build time from a committed snapshot (`scripts/update-blocklist.sh`) |

## Update framework

| Component | License | Notes |
|---|---|---|
| [Sparkle](https://github.com/sparkle-project/Sparkle) | MIT | Pinned at commit `79bc9e8` (2.9.5) in `project.yml`; linked into the macOS app only |

## SwiftPM dependencies (`Packages/QwaveKit`)

| Package | License (SPDX) |
|---|---|
| [swift-log](https://github.com/apple/swift-log) | Apache-2.0 |
| [swift-nio](https://github.com/apple/swift-nio) | Apache-2.0 |
| [swift-collections](https://github.com/apple/swift-collections) | Apache-2.0 |
| [swift-atomics](https://github.com/apple/swift-atomics) | Apache-2.0 |
| [swift-system](https://github.com/apple/swift-system) | Apache-2.0 |
| [swift-syntax](https://github.com/swiftlang/swift-syntax) | Apache-2.0 |
| [swift-url](https://github.com/karwa/swift-url) | Apache-2.0 |
| [EventSource](https://github.com/mattt/eventsource) | MIT |
| [mcp-swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) | MIT |
| [swift-custom-dump](https://github.com/pointfreeco/swift-custom-dump) | MIT |
| [swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing) | MIT |
| [xctest-dynamic-overlay](https://github.com/pointfreeco/xctest-dynamic-overlay) | MIT |

The iOS lane links the same QwaveKit modules as macOS; its dependency set is
identical except Sparkle (macOS-only) and anything under `#if canImport(AppKit)`.

*the constellation · 0 + 1 · fine touch from within · vaked.dev*
