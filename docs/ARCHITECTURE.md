# Qwave architecture

Qwave is a thin AppKit application over the system WebKit engine. The browser
does not embed Chromium or Electron: WebKit owns page rendering and web-content
processes, while Qwave owns the browser chrome, policy decisions, storage
boundaries, and optional network services.

## Runtime shape

```text
Qwave.app
├── AppKit shell + SwiftUI settings
├── BrowserEnvironment (@MainActor service graph)
├── QwaveKit (local Swift package)
│   ├── BrowserCore       tabs, containers, navigation, hibernation
│   ├── Shields           content rules, HTTPS-First, blocklist updates
│   ├── Persistence       SQLite database and actor-isolated stores
│   ├── MemoryWave        encrypted memory substrate and providers
│   ├── Summarize         on-device page summarisation (FoundationModels, availability-gated)
│   ├── VPNKit            Mullvad API, relays, tunnel lifecycle
│   ├── PostQuantum        Keccak, ML-KEM-768, hybrid (PQ+classical) KEM
│   ├── WebExtensions      Manifest V3 registry and browser.* bridge
│   ├── URLIdentity        WHATWG-compatible host identity
│   ├── FeatureFlags       guarded WebKit SPI access
│   └── QwaveSupport       logging, keychain, egress allowlist
└── PacketTunnel.systemextension
    └── WireGuardKit + NetworkExtension provider
```

`Packages/QwaveKit/Package.swift` and `project.yml` are the source of truth.
The Xcode project is generated and must not be edited by hand.

## Dependency direction

The dependency graph is intentionally one-way:

```text
QwaveApp
   ├── BrowserCore ──┬── Shields ── Persistence ── QwaveSupport
   │                 ├── FeatureFlags
   │                 └── URLIdentity
   ├── VPNKit ───────┬── PostQuantum
   │                 └── QwaveSupport
   ├── MemoryWave ───┬── Persistence
   │                 └── QwaveSupport
   ├── Summarize ────┬── BrowserCore
   │                 └── QwaveSupport
   └── WebExtensions ─── QwaveSupport

PacketTunnel ─── QwaveTunnelKit (VPNKit + QwaveSupport) ─── WireGuardKit
```

`BrowserCore` is the convergence point for browser behavior: it wires tabs,
WebKit factories, navigation, shields, and hibernation. Feature modules do not
reach into the AppKit shell. The app supplies adapters and owns presentation.

## Isolation and data flow

### Browser data

`ContainerRegistry` maps profiles to separate
`WKWebsiteDataStore(forIdentifier:)` stores. Cookies, caches, service workers,
and local storage do not cross container identifiers. Burner tabs use
`WKWebsiteDataStore.nonPersistent()`, skip history, and are excluded from
session restoration. Removing a profile removes the WebKit store and its
container-scoped database rows.

### Navigation and shields

`NavigationCoordinator` applies URL identity, HTTPS-First, per-site JavaScript
policy, and content-rule selection before a navigation proceeds. `URLIdentity`
uses the WHATWG/WebKit-compatible parser so policy hosts match the host WebKit
actually loads. `RuleListCompiler` compiles the committed EasyList/uBlock
snapshot into native `WKContentRuleList` objects; rules are enforced by WebKit
rather than injected JavaScript.

### Persistence and MemoryWave

`SQLiteDatabase` is an actor owning the SQLite connection and prepared-statement
cache. `HistoryStore`, `BookmarkStore`, `SessionStore`, and `MemoryStore` keep
database mutations on that actor boundary. Multi-step writes that depend on an
inserted row ID execute in one actor turn. Sendable model values cross back to
the UI; SQLite handles and rows do not.

`MemoryWave` adds container-scoped AES-GCM storage, provenance, salience, and
optional provider calls. Local remember/recall stays on device. Remote
inference is explicit and opt-in; its network behavior is documented in
[docs/NETWORK.md](NETWORK.md).

### On-device Summarize

`SummarizeSession` wraps FoundationModels behind `canImport` +
`#available(macOS 26, *)`; the feature vanishes cleanly when the model is
unavailable or Apple Intelligence is disabled, and defers while the energy
tier is not `.normal` (memory pressure included). An explicit command runs the
readability extractor, then a **respond-only** generation — the stream path
refuses this workload on macOS 26.4 (see [docs/SUMMARIZE.md](SUMMARIZE.md)) —
and renders inert selectable text. Nothing is persisted; nothing egresses.

### Concurrency

QwaveKit uses Swift 6 language mode with complete strict concurrency. The
default ownership rules are:

- `@MainActor` for AppKit, SwiftUI-facing services, WebKit objects, and UI
  observation.
- Actors for mutable persistence, memory, and service state that can outlive a
  UI callback.
- `Sendable` structs/enums for configuration, records, errors, and test values.
- Native async WebKit APIs where available; no new continuation wrappers for
  APIs that already provide async alternatives.

The NetworkExtension provider has a legacy SDK-shaped mutable surface. Its
compatibility annotations are deliberately confined to
`Sources/PacketTunnel/PacketTunnelProvider.swift`; they are not a license to
weaken QwaveKit's actor contracts.

## VPN and post-quantum path

The app stores the Curve25519 device private key in the shared Keychain group.
Only `TunnelSessionConfig` crosses into `providerConfiguration`; tests assert
that it contains no key material. `TunnelManager` owns the
`NETunnelProviderManager` lifecycle and status stream. The provider starts
WireGuard through WireGuardKit and, when enabled, negotiates a hybrid PSK:

```text
Qwave / PacketTunnel ── ML-KEM-768 ──── PSK ──┐
                                              ├── hybrid session ── relay
Qwave / PacketTunnel ── Curve25519 handshake ─┘
```

If the quantum-resistant negotiation fails while enabled, the tunnel start
fails closed instead of silently falling back to a classical-only session.
See [docs/VPN_STAGE_B.md](VPN_STAGE_B.md) and [docs/CRYPTO_REVIEW.md](CRYPTO_REVIEW.md).

## Network ownership

Qwave distinguishes between its own requests, page traffic initiated by a
navigation, and WebKit service traffic. Category-A requests are guarded by a
committed host allowlist and `EgressGuardTests`. New Qwave-owned network code
must document its host, trigger, opt-in state, and test coverage in
[docs/NETWORK.md](NETWORK.md).

## Testing boundaries

```sh
swift test --package-path Packages/QwaveKit -c release
```

The package suite covers pure state machines, URL identity, blocklist
compilation, actor persistence behavior, cryptographic known-answer tests,
VPN configuration, WebExtensions messaging, egress policy, and summarization
gating. The app target
is verified separately through XcodeGen and an unsigned macOS build. Signed VPN
activation requires the entitlements described in [docs/SIGNING.md](SIGNING.md).
