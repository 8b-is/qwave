# Qwave

A WebKit-native, macOS-only browser that takes the best idea from each of the
big three and drops the baggage:

| From    | Feature                                                                 |
|---------|-------------------------------------------------------------------------|
| Firefox | **Containers** — per-tab isolated storage universes (Work / Personal / burner tabs) |
| Brave   | **Shields** — declarative ad/tracker blocking + HTTPS-first, per-site toggles |
| Chrome  | Nothing, actually — but sites think we're Safari, which they treat better |
| Safari  | The engine itself: system WebKit, the most battery-efficient thing that can render a web page on a Mac |
| Mullvad | **Built-in WireGuard VPN** with a staged path to quantum-resistant tunnels |

Plus a Safari Technology Preview-style **experimental web features** pane —
WebKit's bleeding-edge feature flags, toggleable per user.

## Status

Stage A. The browser (tabs, containers, shields, hibernation, feature flags,
history/bookmarks, downloads, find-in-page, session restore) is code-complete
and CI-built. The VPN is code-complete end-to-end (API client → keys → relays
→ Network Extension packet tunnel via WireGuardKit) but **requires signing
with your Apple Developer team** to actually run — see
[docs/SIGNING.md](docs/SIGNING.md). Quantum-resistant PSK exchange is a
designed seam, not yet implemented — see [docs/VPN_STAGE_B.md](docs/VPN_STAGE_B.md).

## Building

On a Mac:

```sh
brew install xcodegen
cd qwave
xcodegen generate
xcodebuild -project Qwave.xcodeproj -scheme Qwave -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
```

or open `Qwave.xcodeproj` in Xcode after `xcodegen generate`. The
`.xcodeproj` is generated and gitignored — edit `project.yml`, never the
project file.

Unit tests (no project generation needed):

```sh
swift test --package-path qwave/Packages/QwaveKit
```

CI does both on every push (`.github/workflows/qwave-ci.yml`, macOS 15
runner) and uploads an unsigned `Qwave.app` artifact.

## Architecture

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Short version: all logic
lives in a local SPM package (`Packages/QwaveKit`) with six modules and full
unit tests; the AppKit app target is a thin shell; the VPN tunnel is a
Network Extension system extension; everything that shapes a page flows
through one `WKWebViewConfiguration` factory.

## Requirements

- macOS 14 (Sonoma) or later — container isolation uses
  `WKWebsiteDataStore(forIdentifier:)`.
- For the VPN: Apple Developer Program membership + a Mullvad account.
