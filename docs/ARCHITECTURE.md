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
│   ├── WebCredentials    login/passkey value types, keychain store, WebAuthn RP-ID policy
│   ├── VPNKit            Mullvad API, relays, tunnel lifecycle
│   ├── PostQuantum        Keccak, ML-KEM-768, hybrid (PQ+classical) KEM
│   ├── WebExtensions      Manifest V3 registry and browser.* bridge
│   ├── URLIdentity        WHATWG-compatible host identity
│   ├── FeatureFlags       guarded WebKit SPI access
│   └── QwaveSupport       logging, keychain, egress allowlist
├── PacketTunnel.systemextension
│   └── WireGuardKit + NetworkExtension provider
└── CredentialProvider.appex
    └── ASCredentialProviderViewController (AutoFill UI) + WebCredentials
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
   ├── WebCredentials    (no QwaveKit dependencies — Foundation + Security only)
   └── WebExtensions ─── QwaveSupport

PacketTunnel ─── QwaveTunnelKit (VPNKit + QwaveSupport) ─── WireGuardKit

CredentialProvider ─── WebCredentials
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

### AutoFill credentials

`WebCredentials` is a deliberately isolated target: it declares **no QwaveKit
dependencies at all** (`Package.swift:83`) and is exported as its own slim,
crypto-free (Foundation + Security only) product so the AutoFill extension
links it *without* pulling in VPNKit or the VPN's crypto stack
(`Package.swift:29-35`, `project.yml` → `CredentialProvider.dependencies`).
It holds the login/passkey value types,
`KeychainWebCredentialStore`, domain matching, and `WebAuthnOriginPolicy` —
the WebAuthn §5.1.3 origin binding, which authorises an `rpId` only when it
equals the frame's origin host or is a registrable-domain suffix of it, so a
cross-origin frame cannot drive a ceremony for an arbitrary relying party.
`WebAuthnOriginPolicy` itself is pure (no WebKit, no URL parser, no keychain —
unlike its module-mate `KeychainWebCredentialStore`) and returns the
*normalized* rpID rather than a bool, so a caller cannot run the ceremony with
a string other than the one authorised. The absent public-suffix list is a
documented limitation in the source, not a silent gap.

`CredentialProvider` is a macOS `app-extension` target
(`Sources/CredentialProvider`, extension point
`com.apple.authentication-services-credential-provider-ui`, declaring
`ProvidesPasswords` and `ProvidesPasskeys`). Its principal class,
`CredentialProviderViewController`, subclasses
`ASCredentialProviderViewController` and reaches the keychain only through
`WebCredentialStore`. It shares the app's keychain access group and app group
via entitlements, so the two processes see the same items without a custom IPC
channel. Credential secrets never cross into `DeviceKeyManager` or the VPN's
key material — that separation is the point of the slim product.

**Today this path is fill-only.** Nothing in `Sources/` calls
`WebCredentialStore.save(_:)`, and `ASCredentialIdentityStore` is not referenced
in Swift source anywhere, so no capture prompt, import flow, or QuickType
registration exists yet ([#72](https://github.com/8b-is/qwave/issues/72), and
`docs/AUTOFILL.md` § Deferred). Read the extension as a reader over keychain
items placed there by other means, not as a password manager with a save flow.

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
navigation, and WebKit service traffic. Category-A hosts are recorded in a
committed allowlist, and — since [#77](https://github.com/8b-is/qwave/issues/77) —
`EgressGuard` (`QwaveSupport/EgressGuard.swift`) is a `URLProtocol` that
consults `EgressAllowlist.permits(host:)` at runtime and fails any request to
a host not listed, wired into every fixed-host Qwave network client
(`MullvadAPIClient`, the DuckDuckGo suggestion provider) plus, process-wide,
any default- or shared-configuration session. It is still not a mechanical
guarantee over new code: a fixed-host client that skips
`EgressGuard.install(into:)` is not caught by anything mechanical, only by
review, and `EgressGuardTests` still pins three known endpoints by hand and
asserts the shields launch path makes no request. New Qwave-owned network
code must add its host to the allowlist, wire `EgressGuard` into its session
if the host is fixed, and document its host, trigger, opt-in state, and test
coverage in [docs/NETWORK.md](NETWORK.md).

## Testing boundaries

```sh
swift test --package-path Packages/QwaveKit -c release
```

The package suite covers pure state machines, URL identity, blocklist
compilation, actor persistence behavior, cryptographic known-answer tests,
VPN configuration, WebExtensions messaging, egress policy, summarization
gating, and credential matching / WebAuthn RP-ID policy. The app target
is verified separately through XcodeGen and an unsigned macOS build. Signed VPN
activation requires the entitlements described in [docs/SIGNING.md](SIGNING.md).
