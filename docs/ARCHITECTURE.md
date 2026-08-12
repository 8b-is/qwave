# Qwave Architecture

WebKit-native macOS browser. No Chromium, no Electron — the rendering engine
is the system WebKit (the same processes Safari uses), which is what makes the
battery story work: Apple's own energy-optimized engine, plus aggressive tab
lifecycle management on top.

## Layout

```
qwave/
├── project.yml                  XcodeGen spec — the single source of truth for
│                                targets/entitlements/plists. *.xcodeproj is generated.
├── Sources/QwaveApp/            App target: thin AppKit shell + SwiftUI panes
├── Sources/PacketTunnel/        Network Extension (system extension) target
├── Packages/QwaveKit/           All logic, as a local SPM package (unit-tested)
│   └── Sources/
│       ├── QwaveSupport/        Logging, SecretStore (keychain / in-memory)
│       ├── Persistence/         SQLite wrapper, History/Bookmarks/Settings/Session
│       ├── BrowserCore/         Tabs, containers, navigation, hibernation, energy
│       ├── Shields/             Content blocking, HTTPS-first
│       ├── FeatureFlags/        WebKit experimental-feature reflection
│       └── VPNKit/              Mullvad API, keys, relays, tunnel management
└── docs/                        This file, SIGNING.md, VPN_STAGE_B.md
```

Dependency rule: `QwaveApp → {BrowserCore, Shields, FeatureFlags, VPNKit,
Persistence, QwaveSupport}`; `PacketTunnel → {VPNKit, QwaveSupport,
WireGuardKit}`. BrowserCore is the only module allowed to import the other
feature modules (it hosts `WebViewFactory`, the convergence point).

## The four pillars

### 1. Tab/container isolation (Firefox containers, WebKit-style)

- WebKit already renders every site in sandboxed, per-site web-content
  processes. On top of that, `ContainerRegistry` maps container profiles to
  `WKWebsiteDataStore(forIdentifier:)` stores — fully separate cookie jars,
  caches, service workers, and local storage per container.
- Ephemeral (burner) tabs get `WKWebsiteDataStore.nonPersistent()` — a fresh
  universe per tab, never written to disk, never recorded in history, never
  restored with the session.
- Deleting a container calls `WKWebsiteDataStore.remove(forIdentifier:)` — the
  whole universe is wiped at the storage layer, plus its history rows.

### 2. Shields (Brave-style) + HTTPS-first

- `RuleListCompiler` compiles the shipped blocklist into a
  `WKContentRuleList` — declarative rules enforced inside WebKit's network
  machinery, not JS-injected after the fact. CI compiles the exact shipped
  JSON so a bad rule fails the PR.
- `ShieldsDirector` reconciles which lists are attached per navigation
  (per-site toggles work like Safari's own per-site content-blocker switch).
- HTTPS-first is two layers: a `make-https` rule list for subresources, and
  `HTTPSFirstUpgrader` (pure state machine) for main-frame navigations with
  one-shot per-host fallback when a site's HTTPS is genuinely broken.
- Per-site JS off uses `WKWebpagePreferences.allowsContentJavaScript` at
  policy-decision time.

### 3. Energy (the reason to be WebKit-native)

- `EnergyGovernor` (pure): thermal state × Low Power Mode × window occlusion →
  tier (normal / conserve / critical) → policy (hibernation timeout, background
  media pause/suspend).
- `HibernationController` (pure, fake-clock tested): which background tabs to
  hibernate. Exempt: selected, pinned, audibly playing media.
- `TabHibernator`: snapshot → capture `WKWebView.interactionState`
  (back/forward stack, scroll, form state) → destroy the web view. A
  hibernated tab holds zero WebKit processes. Restore rebuilds the web view
  and reassigns `interactionState`.
- One coalesced `DispatchSourceTimer` (30s + 10s leeway) drives everything;
  there are no per-tab timers anywhere.
- Restored sessions start hibernated-by-design: tabs are recreated lazily on
  first selection, so relaunching a 40-tab session spawns one web process.

### 4. Bleeding-edge web standards

- `FeatureFlagService` enumerates WebKit's runtime feature flags (the set
  Safari Technology Preview exposes) via the `_WKFeature` SPI, discovered
  reflectively with `responds(to:)` guards everywhere — if the SPI vanishes,
  the pane reports unavailable and nothing else is affected. A CI canary test
  asserts exactly this either/or.
- Overrides persist in defaults and are applied to every new
  `WKPreferences` by `WebViewFactory`.
- `webView.isInspectable = true` — Web Inspector everywhere.

## VPN

See `docs/VPN_STAGE_B.md` for the quantum-resistant roadmap and
`docs/SIGNING.md` for activation. Summary:

- `MullvadAPIClient` (REST, URLProtocol-mockable) — token, device
  registration (WireGuard pubkey → in-tunnel addresses), relay list.
- `DeviceKeyManager` — Curve25519 key in the keychain only; the tunnel
  extension reads it via shared keychain group. `TunnelSessionConfig` (what
  crosses into providerConfiguration) is tested to contain no key material.
- `TunnelManager` — `NETunnelProviderManager` lifecycle + status publishing.
- `PacketTunnelProvider` — WireGuardKit's `WireGuardAdapter`; the
  `EphemeralPeerNegotiating` seam runs before handshake (Stage A: noop).

## Testing strategy

`swift test --package-path qwave/Packages/QwaveKit` runs everything headless:
pure state machines (omnibox, HTTPS-first, hibernation, energy, relays) plus
two "real WebKit" checks — rule-list compilation of the shipped JSON and the
feature-flag SPI canary. AppKit chrome stays thin and logic-free by rule.

## CI

`.github/workflows/qwave-ci.yml`: `unit-tests` (SPM, fast) → `build-app`
(xcodegen + xcodebuild, unsigned, uploads the .app artifact). The Go bridge
for WireGuardKit builds in a pre-build make step (Go is preinstalled on
GitHub's macOS runners).
