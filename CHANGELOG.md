# Changelog

All notable changes to Qwave will be documented in this file.

## [Unreleased]

### Security
- **WebAuthn/passkey origin binding.** The passkey bridge accepted the `rpId`
  a page supplied without ever looking at which frame sent it, and its shim was
  injected into every frame (`forMainFrameOnly: false`), so a cross-origin
  iframe — an ad frame, an embedded widget — could start a real platform
  passkey ceremony for *any* relying party it named. Requests are now refused
  unless they come from the top-level frame and the requested `rpId` equals, or
  is a registrable-domain suffix of, the requesting frame's own origin host
  (`WKFrameInfo.securityOrigin`). The match breaks on a label boundary, so
  `evil-example.com` cannot claim `example.com`, and the `rpId` is canonicalised
  through the same WHATWG parser WebKit uses, so an IDN or percent-encoded
  spelling cannot slip past the check. The ceremony then runs with the value
  the policy returned as authorised, not with the bridge's own input — the two
  can still differ, because WHATWG canonicalisation keeps a trailing root dot
  (`example.com.`) that the policy drops — so the value validated is the value
  the ceremony runs with. Legitimate same-origin and subdomain → parent-domain
  ceremonies are unaffected.
- **WebExtensions bridge hardening.** Four fixes to the `browser.*` bridge:
  - Bridge replies and dispatched messages are now encoded with a single
    JSON-based JS-literal encoder instead of a hand-rolled escaper that only
    escaped `"`. `JSONSerialization` refuses a bare top-level string and raises
    an uncatchable Objective-C exception, so *every* string payload took the
    unsafe path — including the `"Unknown method: <method>"` error reply built
    from a page-supplied method name. Any page could reach it with one
    `postMessage`. Values are now array-wrapped before serialisation (the same
    approach already used by `WebAuthnBridge.jsonLiteral`), backslashes,
    newlines, quotes and U+2028/U+2029 are escaped, and values JSON cannot
    represent degrade to `null` rather than raising.
  - On untrusted web pages, the bridge, its `qwaveExtension` message handler,
    and every injected content script now run in a dedicated `WKContentWorld`
    instead of the page's own JavaScript world, so a hostile page can no longer
    observe, wrap, or replace them. The extension's own popup chrome is
    deliberately excluded: it keeps running in the page world of its own
    dedicated web view, which loads nothing but the extension's `popup.html`,
    because that document *is* the extension and isolating it from itself would
    only break `browser.*`. The content world is now a property carried by each
    surface rather than a global constant, so a reply is always evaluated into
    the world the call came from.
  - Bridge replies are routed back to the web view the call arrived from
    instead of through a single shared responder slot pointed at the
    last-opened popup, so a reply can no longer land on the wrong surface.
  - With no extensions installed, no bridge is injected into tabs at all.

### Changed (BREAKING — crypto core)
- **ML-KEM-768 now conforms to FIPS 203, verified against the official NIST
  ACVP vectors.** 29 ML-KEM-768 cases (keyGen, encapsulation, decapsulation,
  encapsulationKeyCheck) — out of 80 ML-KEM-768 cases upstream, or 70
  excluding the deliberately-skipped `decapsulationKeyCheck` group — are
  committed verbatim from `usnistgov/ACVP-Server`
  with provenance in
  `Packages/QwaveKit/Tests/PostQuantumTests/Fixtures/mlkem768_acvp_vectors-ATTRIBUTION.txt`.
  When they were first wired up, **0 of the 21 then-runnable cases passed**;
  all 29 pass now. Eight deviations were fixed, each of which independently
  destroyed interoperability with any conformant peer:
  - `SampleNTT` (Alg 7) did no rejection sampling — it took one fixed 384-byte
    SHAKE128 squeeze and accepted 12-bit values ≥ q. It now streams and
    rejects, via a new incremental `Keccak.SHAKE128Reader`.
  - The matrix index bytes were transposed in *both* KeyGen and Encrypt
    (self-consistent, interoperable with nothing).
  - Encaps/decaps applied a Kyber-round-3 KDF `SHAKE256(K ‖ ct)` that was
    removed during standardisation; K is now returned directly.
  - `H(ek)` used SHAKE256 where FIPS 203 specifies SHA3-256, changing both
    the ciphertext and the shared secret.
  - `z` was derived from `d`; it is an independent seed, so keygen is now
    `keygen(d:z:)`.
  - The decapsulation key was laid out `dkPKE‖ek‖z‖H(ek)`; Alg 16 specifies
    `dkPKE‖ek‖H(ek)‖z`. Decaps now reads the stored `H(ek)` instead of
    recomputing it.
  - Encaps had no input validation; FIPS 203 §7.2 type and modulus checks are
    implemented as `MLKEM768.validateEncapsulationKey`, and `ByteDecode₁₂`
    reduces mod q.

  No migration and no compatibility shim: nothing PQ-derived is persisted (the
  PSK is call-scoped and goes straight onto the WireGuard peer) and no
  conformant peer is deployed.
- **The Classic McEliece leg was removed.** `ClassicMcEliece348864` did not
  implement Classic McEliece — McEliece-form 436-byte ciphertext where the
  standard is Niederreiter-form at 96 bytes, secret key 5330 vs 6492, a
  bespoke shared-secret derivation, no implicit rejection, and none of
  SeededKeyGen's σ₁/σ₂ expansion, FieldOrdering, Irreducible or Benes control
  bits. It was a different scheme wearing a standard's name and had no
  conformance vectors, so it was dropped rather than corrected. `HybridKEM`
  now carries ML-KEM-768 alone: ek 262304 → 1184, dk 7730 → 2400,
  ct 1524 → 1088 bytes, and `EphemeralPeerRequest` loses `mceliece_public_key`.
  "Hybrid" continues to mean post-quantum + classical Curve25519.

  **Behaviour change, with a tunnel consequence — read this before upgrading.**
  Dropping the code-based leg removed the *only throwing decapsulation path*.
  `HybridKEM.decapsulate` now throws on wrong input sizes and on nothing else:
  a tampered, corrupted or hostile ciphertext of the right length returns a
  well-formed but **wrong** shared secret, because that is what ML-KEM's
  implicit rejection is specified to do (FIPS 203). The KEM is correct; the
  caller is what changes. In `Sources/PacketTunnel/PacketTunnelProvider.swift`
  the daily rekey installs that wrong PSK over a working tunnel, logs
  "Ephemeral peer PSK rotated", and does not retry for 24 hours — so a single
  bad rekey response can take a working tunnel down for a day while reporting
  success. Tunnel *start* is unaffected (a wrong PSK there simply fails
  closed, which is the intent).
  Scope, precisely: the protection that disappeared was always partial. With
  the 1524-byte ciphertext, corruption confined to the 1088-byte ML-KEM half
  already produced a wrong PSK with no throw (the old suite's
  `mlkemBitFlipChangesSharedSecret` asserted exactly that); only corruption
  touching the 436-byte McEliece half threw. Against a deliberately hostile
  relay it was worth nothing, since the relay could always send a well-formed
  McEliece half. No fix is included here — a correct one has to corroborate
  the new PSK against a real handshake before discarding the old one, which
  is a provider design change, not a patch. Tracked in issue #91.

### Added
- **AutoFill credential save path** (#72): AutoFill was fill-only — the
  keychain store's `save` path existed and was tested, but nothing under
  `Sources/` ever called it, and `ASCredentialIdentityStore` appeared nowhere
  in Swift source, so a fresh install had no way to get a login in and the
  AutoFill bar never showed proactive suggestions. `PasswordCaptureBridge`
  now observes password-form submissions (main frame only, non-private tabs
  only) and prompts to save; confirming routes through the new
  `CredentialSaver`, which writes the login to the keychain **and** registers
  its identity with `ASCredentialIdentityStore` via the new
  `SystemCredentialIdentityStore`, so a saved login is both fillable and
  proactively suggested. See `docs/AUTOFILL.md`.
- **A regression pin for `HybridKEM`'s own derivation constants**
  (`Fixtures/hybrid_psk_regression_pin.json`, `HybridKEMPinSuite`). Deleting
  `hybrid_vectors.json` had left `pskLabel` ("qwave/pq-psk/v1"),
  `mlkemKgLabel`, `mlkemEncLabel` and the 64-byte seed split into `d`/`z`
  with nothing pinning them — all four are wire-visible values both peers
  must agree on, and every one could have been edited with the whole suite
  staying green. This fixture is **self-generated and is not conformance
  evidence**; it is labelled as such in the file, in the suite doc comment
  and in `docs/CRYPTO_REVIEW.md`'s checklist. It is also the only fixture in
  the repo that may ever be regenerated — the ACVP vectors never are.
- **Summarize Page** (macOS 26+ on Apple Silicon with Apple Intelligence):
  on-device page summarisation via FoundationModels, behind the Summarize
  menu (⌥⌘S) and a toolbar button. Respond-only (no streaming), retry ≤3 on
  the model's nondeterministic refusals with a neutral failure string,
  availability tri-state with clean vanish (including the self-healing
  `modelNotReady` state re-checked on foreground), and an energy gate that
  quietly defers inference while the Mac is under memory pressure or not at
  the normal energy tier. The feature is absent on unsupported systems and
  never makes a network request — the model, the page text, and the summary
  never leave the Mac. See `docs/SUMMARIZE.md`.

### Removed
- The self-generated `mlkem_vectors.json`, `mceliece348864_vectors.json` and
  `hybrid_vectors.json` fixtures (3.2 MB). They were round-trip fixtures
  produced from the implementation itself, so they proved self-consistency and
  never conformance, and they went stale the moment the code was corrected.
  The official ACVP vectors replace them as the oracle.

### Fixed
- Memory Wave's remote OpenAI-compatible provider now applies an explicit
  request timeout (30s idle, 60s overall), so an endpoint that hangs or
  dribbles bytes can no longer stall inference indefinitely.
- Memory Wave's remote provider no longer follows redirects off the endpoint
  you configured. A 307/308 replays the POST — method and body, meaning the
  whole page text — at whatever host the response names; that contradicted
  Settings' promise that pages go "to this endpoint". Redirects are now
  followed only when they stay on the same HTTPS origin (host and port).
- **Memory Wave no longer destroys its own master key.** If the stored key was
  present but not 256 bits, `MemoryCipher.loadOrCreateKey` fell through to the
  first-run path and overwrote it with a fresh key, making every existing
  memory permanently undecryptable. It now fails closed on both halves: a
  stored-but-malformed key throws `MemoryCipherError.malformedKey` and is left
  byte-for-byte intact, and the create branch writes through the new add-only
  `SecretStore.addSecret`, which throws `SecretStoreError.duplicateItem` rather
  than overwriting — so a key that exists but reads back as absent (a keychain
  access-group change, an item in another keychain in the search list, two
  first runs racing) survives instead of being replaced. Memories are locked
  rather than lost, and the app logs the locked state distinctly. Genuine first
  run (no secret stored) is unchanged, and `setSecret` keeps its
  overwrite semantics for the callers that need update-in-place.
  Note: rows that fail to decrypt are still dropped silently by
  `MemoryStore.decode`; that half is tracked separately in issue #84.

## [1.0.0] - 2026-08-14

**Production Release: Web3 & WebKit-Native Sovereign macOS Browser.**

> **Errata — 2026-08-15.** The Highlights below are left as they were published.
> Four of them do not survive a check against the code, and the corrections are
> recorded here rather than by rewriting the entry:
>
> 1. **"Swift 5.10 / Swift 6 … across 10 modules"** — there is no Swift 5.10 in
>    the package and the module count is wrong. `Packages/QwaveKit/Package.swift`
>    is `swift-tools-version:6.0` and applies
>    `.swiftLanguageMode(.v6)` + `-strict-concurrency=complete` to **every**
>    target (`Package.swift:1`, `:4-7`). On the module count, applying the same
>    as-of-publication standard used in item 3 below: at the tag the package had
>    **11** library targets, not 12 — `git show v1.0.0:Packages/QwaveKit/Package.swift`
>    has no `WebCredentials`, which arrived with AutoFill after 1.0.0. So the
>    published figure was wrong when it was written, and the count is **12**
>    today (QwaveSupport, URLIdentity, Persistence, Shields, FeatureFlags,
>    WebCredentials, BrowserCore, PostQuantum, VPNKit, WebExtensions,
>    MemoryWave, Summarize — `Package.swift:52-117`) alongside 13 test targets.
>    Neither number is 10.
> 2. **"Sub-45.7MB/tab reclamation floor"** — 45.7 MB/tab is a single
>    measurement of a synthetic ballast fixture, not a floor, and "sub-" points
>    the wrong way for a reclamation figure. The origin is `docs/ENERGY.md:87-93`
>    and the 0.3.1 entry below. The **enforced** gate in
>    `BrowserCoreTests/HibernationReclaimTests` is different and lower: more than
>    half the pre-hibernation footprint reclaimed, **and >10 MB per tab**
>    (`HibernationReclaimTests.swift:163-170`).
> 3. **"WebGPU Acceleration: Native WebKit WebGPU pipeline with zero-latency
>    visual waveform rendering"** — no such pipeline exists. `rg WebGPU` over
>    `Sources/` and `Packages/QwaveKit/Sources/` returns nothing; the only
>    WebGPU work in the tree is the research probe and benchmark under
>    `research/01-webkit-browser-engine/webgpu-surface/` and
>    `research/03-gpu-metal-compute/`. WebGPU in a `WKWebView` is WebKit's own:
>    the probe measured `navigator.gpu` as **default-on**, with the `_WKFeature`
>    `WebGPUEnabled` flag **inert** (`research/.../webgpu-surface/README.md:14-16`,
>    `:36-40`). Qwave renders no waveform on the GPU — the "waveform" in the UI
>    is the SF Symbol named `waveform` (`MemoryWavePanel.swift:17`). Note that
>    the 0.4.3 entry further down describes WebGPU as gated behind
>    `WebGPUEnabled` plus a secure context; that was the honest reading at the
>    time and the probe has since resolved it as stale. The README's research
>    index carries the current finding.
> 4. **"Xcode Cloud & Multi-Host CI: Automated cross-architecture test
>    verification"** — no Xcode Cloud build gates this repo, and CI is not
>    multi-host. What exists is *preparation*: the two hook scripts
>    `ci_scripts/ci_post_clone.sh` and `ci_scripts/ci_post_xcodebuild.sh` plus
>    the setup guide `docs/XCODE_CLOUD.md`, which states that creating the
>    workflow requires manual steps in Xcode / App Store Connect and "cannot be
>    scripted from the repo" (`docs/XCODE_CLOUD.md:44-47`). The CI that actually
>    runs is GitHub Actions — `ci.yml`, `claude-code-review.yml`, `claude.yml`,
>    `release.yml` — and every job in `ci.yml` targets the single runner label
>    `blacksmith-6vcpu-macos-15`, so there is no architecture matrix. The signed
>    release build is real (`release.yml`).

### Highlights
- **Engine**: Swift 5.10 / Swift 6 strict concurrency architecture across 10 modules in `QwaveKit`.
- **MemoryWave & Energy Governor**: Sub-45.7MB/tab reclamation floor with zero foreground interruption.
- **Post-Quantum Cryptography**: ML-KEM-768 and Classic McEliece 348864 hybrid key encapsulation.
- **Shields & Container Isolation**: Multi-engine UBO compiler + ephemeral cookie/state isolation per container.
- **WireGuard PacketTunnel**: Native WireGuardKit network extension integration.
- **WebGPU Acceleration**: Native WebKit WebGPU pipeline with zero-latency visual waveform rendering.
- **Xcode Cloud & Multi-Host CI**: Automated cross-architecture test verification and signed release builds.

## [0.6.0] - 2026-08-14

Speedometer chrome-tax pass and VPN system-extension test build.

### Performance (chrome tax)
- **Energy tick** yields to foreground activity: never hibernate a loading tab,
  skip the whole tick while the visible tab is mid-load, skip the discarded
  media-playback probe for the selected tab. Battery posture preserved
  ("ticks resume when idle" test).
- **Shields** `applyLists` caches the attached rule-list set by object identity
  and no-ops when unchanged, instead of remove-all + re-add on every navigation.
- **Chrome refresh** coalesced to one per runloop turn (was one per KVO tick,
  incl. `estimatedProgress`, which drives no visible chrome).
- **Cold start**: the warm process pool is warmed at launch instead of ~30s later.
- **Launch**: first window + local start page paint without awaiting shields/VPN
  warmup; the first network navigation gates on the rule-list compile, so shields
  are never bypassed (issue #19).
- Speedometer harness, committed baseline, `os_signpost` instrumentation, and a
  non-blocking CI perf lane (`docs/PERF.md`).

### VPN
- App entitlement trimmed to the `packet-tunnel-provider-systemextension`
  network-extension mode, matching the App ID capability / provisioning profile.

## [0.5.0] - 2026-08-14

Swift 6 language mode throughout — structural foundations completed.

### Swift 6 migration
- **Package default**: `.swiftLanguageMode(.v6)` with `strict-concurrency=complete`.
  All 10 QwaveKit modules and both app targets (QwaveApp, PacketTunnel) compile
  in Swift 6 mode. No per-target `.v5` pins remain.
- **App-layer**: `SWIFT_VERSION: "6.0"`, `SWIFT_STRICT_CONCURRENCY: complete` in
  `project.yml`. QwaveApp and PacketTunnel both green.
- **VPNKit**: `TunnelManager.deinit` observer teardown restructured for v6's
  stricter `deinit` isolation. `MullvadVPNService` async flows and `AccountStore`
  SecretStore writes adjusted for `sending` correctness.
- **Shields**: `WKContentRuleList` continuation code updated for v6's stricter
  `sending` checks on `@Sendable` closures.
- **FeatureFlags**: ObjC-runtime reflection (`AnyObject.perform`, guarded KVC,
  `unsafeBitCast` IMPs) kept within the isolation domain.
- **251 tests**, 0 failures (9 new tests validating v6 concurrency patterns).

### Zig kernel integration
- **PacketTunnel data plane**: `libqpacket.a` static library compiled from
  Zig (`zig-core/src/packet.zig`) via XcodeGen preBuildScript — same pattern
  as the WireGuard Go bridge.
- **Packet inspection**: IPv4/IPv6 validation, protocol classification (TCP/UDP/
  ICMP), malformed-packet rejection. Extended stats via `qpacket_filter_stats_extended()`.
- **CI**: `zig-validation` job builds, tests, and validates the blocklist.
  Zig required in the app-build job for the preBuildScript.
- **Build pattern documented**: `docs/ZIG_INTEGRATION.md` records the three
  load-bearing fixes (Zig in CI, `$ARCHS` + `lipo` for universal, `-fcompiler-rt`
  for cross-arch runtime symbols).

### Performance (carried forward from earlier sessions)
- OmniboxSuggester: 4,370→1,011 mallocs per keystroke (−77%)
- ARC metrics (retainCount, releaseCount, retainReleaseDelta) as CI gates (5% p90)
- `warmProcessCount` wired in WebViewFactory (1 at .normal tier, 0 at conserve/critical)
- `@inlinable` annotations removed (zero measurable effect on ARC or allocation)
- Measurement protocol in `hot_paths.md`: quiesce check, N≥5, reject unquiesced runs

## [0.4.4] - 2026-08-13

"Prove what it sends" — network-egress hardening. A sovereign browser must
be able to prove what it sends; now it can.

### Added
- **`docs/NETWORK.md`**: a complete, user-readable inventory of every
  outbound connection, split into Qwave's own egress (Category A), page
  loads (B), and WebKit's own service traffic (C). Linked from Settings.
- **Egress regression gate**: a committed `EgressAllowlist` of the hosts
  Qwave's own code may contact, enforced by `EgressGuardTests` — CI fails if
  a change adds a connection to an un-allowlisted host, and the launch path
  is asserted to make zero requests.
- **Mullvad API certificate pinning**: `api.mullvad.net` is pinned to the
  ISRG roots (X1 + X2 SPKI, in addition to system trust, fail-closed) so a
  mis-issued certificate cannot feed a manipulated relay set. Full rotation
  design and threat model in `docs/PINNING.md`.
- **Visible auto-update consent**: Settings → General → "Check for updates
  automatically"; off means zero background update requests. Sparkle still
  gates the first automatic check behind its permission prompt.

### Changed
- **Removed the launch-time blocklist fetch** — it fetched the upstream
  EasyList at every launch and discarded the result (egress that bought the
  user nothing). The blocklist ships as a committed build-time snapshot;
  Qwave now makes no network request at startup.

### Fixed
- The category-C finding: WebKit's fraudulent-website warning (Safe
  Browsing) is disclosed as on-by-default egress to Apple on navigation.
- Release workflow verifies every embedded Sparkle helper is Developer ID
  signed + hardened before notarization (the deep-sign gap that cost a
  release cycle now fails fast and clearly).

## [0.4.3] - 2026-08-13

### Added
- **Memory nibbles**: pages are cut into small tagged markdown files
  (`~/Library/Application Support/Qwave/nibbles/YYYY/MM/*.md`) with YAML
  front matter (`tags`, `url`, wave identity). Recall `#tag` from the start
  page or Ask. Encrypted SQLite still holds the full Cognitive wave.

### Changed
- **CI runs the test suite in Release** — the Classic McEliece keygen KATs
  dominate the suite and are ~10× faster optimized (a keygen vector: ~40s →
  ~3.7s), keeping the run comfortably inside the job timeout. KATs are
  deterministic, so this changes only speed, not outcomes.
- Added `research/BLEEDING-EDGE-2026.md` (Apple Silicon M5 / Metal 4,
  WebGPU, Wasm 3.0 / WASI, Swift 6.3/6.4, Zig 0.16, Mac interop) with a
  repo-verified correction: WebGPU in `WKWebView` is not on by default —
  it is the `_WKFeature` `WebGPUEnabled` plus a secure context, reachable
  through `FeatureFlagService`'s existing reflection.

## [0.4.2] - 2026-08-13

### Added
- **Remember Everything** (Settings → Memory Wave, off by default): every
  non-private page is captured locally as a Cognitive `browse` wave. Private
  and ephemeral tabs still never write.
- **Timeline slate** (`qwave://timeline`): liquid-glass panel over the wave
  scene with day groups and Summarize today / week / everything. Summaries
  persist as even-lane waves. Remote providers receive titles and times only
  — never page bodies.

## [0.4.1] - 2026-08-13

Wave start page, error pages, and a real markdown reader.

### Added
- **Lost-in-the-Math WebGL scene** for new tabs (`qwave://start`), HTTP
  404/410/5xx, and connection failures — same domain-warped shader, Escape
  Sequence back to the start page.
- **Markdown reader** (file or web): headings, tables, task lists, fenced
  mermaid (bundled Mermaid 11, `securityLevel: strict`), KaTeX math
  (`$…$` / `$$…$$`). Original source is kept for Memory Wave.
- **Directory fallback**: `index.html` / `index.htm`, then `README.md`,
  then a listing. File → Open…, drag-and-drop, and omnibox `/path` or `~`.
- **Remember page or selection** from the markdown chrome or ⌘⇧R.


## [0.4.0] - 2026-08-13

Memory Wave — the browser node of the MEM8 substrate.

### Added
- **`MemoryWave` module**: Swift port of the MEM8 cognitive substrate used
  across `mem8`, `mem8v2`, and `8b-Mem8`. 79-byte little-endian `WaveInt`
  frames (Cognitive vs Nexus provenance, checksummed), sparse 256×256×65536
  grid, Marine salience, AES-GCM sealed payloads, container isolation.
- **Fail-closed policy**: ephemeral/private tabs cannot write; stored
  Cognitive waves never egress to a remote provider; HTTPS-only remote
  endpoints; inference gated on `EnergyGovernor` `.normal` (now also
  samples memory pressure).
- **AI-agnostic providers**: off (remember only), on-device Apple
  Intelligence when present, or any OpenAI-compatible HTTPS
  `chat/completions` endpoint (default `https://api.x.ai/v1` / `grok-4.6`).
  API keys live in the Keychain.
- Settings pane, toolbar waveform, and **Memory Wave** menu
  (Remember / Summarize / Ask). Nothing runs unless the user asks.

## [0.3.1] - 2026-08-13

"Prove the claims" — no new user-facing features; this release measures
what v0.3.0 asserted, pays down its surface, and is the first build shipped
through the fully signed + notarised + Sparkle-appcast pipeline.

### Added
- **Blocklist performance budget** (`docs/ENERGY.md`): cold compile of the
  59,657-rule list measured at 2.8–3.1 s, warm relaunch load ~135 ms,
  27.7 MB compiled artifact, ~130 ms max main-thread stall — budgets now
  test-enforced. A list-content update no longer holds first paint hostage:
  `RuleListCompiler.availableList` serves the previous compiled version
  while the fresh one compiles in the background.
- **Hibernation claim proven**: process-tree measurement (WebContent pids +
  `proc_pid_rusage`) shows hibernation terminates the tab's content
  processes entirely — 137 MB → 0 MB across 3 ballast tabs, 45.7 MB/tab,
  wake-to-interactive 138 ms; regression-floored in CI. Hibernate/wake now
  emit `os_signpost` intervals for Instruments.
- **In-process benchmark suite** (`Benchmarks/`, package-benchmark):
  OmniboxParser (the WHATWG path measured, not asserted), OmniboxSuggester,
  HistoryStore at 50k rows, UBORuleListCompiler, SessionRestorer — CI
  checks `mallocCountTotal` against committed thresholds.
- `THIRD-PARTY-NOTICES.md` (EasyList redistribution determination) and the
  rule-update-path disclosure in `docs/BLOCKLIST.md`.

### Changed
- `TabManager` storage is now `OrderedDictionary` (swift-collections
  1.6.0): ordered + unique + O(1) keyed lookup; drag-reorder via
  `move(indices:to:)`; behavior unchanged.
- One isolated swift-format reformat (`.git-blame-ignore-revs` skips it);
  `swift-format lint --strict` gates CI; CI Xcode pinned to 16.4
  (asserted); all GitHub actions pinned to full commit SHAs; Go installed
  for the WireGuard bridge on Blacksmith runners.
- Notarisation uses an App Store Connect API key
  (`NOTARY_KEY_B64`/`NOTARY_KEY_ID`/`NOTARY_ISSUER_ID`).
- Periphery dead-code sweep: two unused McEliece helpers removed
  (KATs re-run green), remaining findings triaged in
  `Packages/QwaveKit/.periphery.yml`, report-only CI job added.

## [0.3.0] - 2026-08-13

### Added
- **Signing, notarisation & auto-updates**: the release workflow builds a
  Developer ID-signed, hardened-runtime, notarised and stapled DMG when the
  signing secrets are configured (unsigned zip fallback otherwise), and
  Sparkle 2.9.5 is embedded with an EdDSA-signed `appcast.xml` published to
  GitHub Releases ("Check for Updates…" in the app menu). CI-signed builds
  carry no Network Extension entitlements until Apple's Developer ID NE
  approval exists — gap and enablement steps in `docs/SIGNING.md`.
- **Canonical host identity (`URLIdentity` module, WebURL 0.4.2)**: shields
  policy keys, HTTPS-first bookkeeping, navigation policy and the omnibox now
  derive hosts through the WHATWG parser WebKit itself follows — closing a
  bypass class where IDN/confusable, percent-encoded, non-decimal-IP,
  backslash and `user@evil@good` URLs were shielded under one identity while
  WebKit loaded another. Container data-store keys were audited: they are
  UUID-based and host-independent, so no change was needed there.
- **EasyList-scale blocklist**: the bundled ads/trackers list is now a
  compiled EasyList snapshot (59,657 rules incl. native `css-display-none`
  cosmetics) generated by `scripts/update-blocklist.sh` using AdGuard's
  SafariConverterLib strictly as an external build-time tool (GPL boundary
  and CC BY-SA 3.0 attribution documented in `docs/BLOCKLIST.md`).
- **Structured logging**: `QwaveLog` categories now front swift-log 1.6.x
  with an os_log backend. Privacy is enforced before the pipeline: string and
  object interpolations are redacted to `<private>` unless explicitly marked
  `.public` (os_log-style `privacy:` syntax preserved at call sites), with
  tests asserting the redacted path.
- **Test upgrades**: parameterised Swift Testing suites for the ML-KEM-768,
  Classic McEliece and Keccak KAT vectors and the uBO filter parser;
  swift-snapshot-testing golden for `UBORuleListCompiler` JSON output; a
  WebKit out-of-process memory measurement protocol in `docs/ENERGY.md`
  (in-process benchmarks cannot see hibernation reclaim).
- **PQ hardening ("Trust & Distribution")**: fail-closed downgrade —
  `quantumResistant` + failed PSK negotiation now blocks tunnel start with a
  user-visible error instead of silently going classic (regression tests
  written before the provider change); daily ephemeral-peer rekey via
  `WireGuardAdapter.update` from a provider timer + wake hook (a failed
  rekey keeps the previous quantum-resistant PSK); negative/tamper KATs
  (truncated keys, wrong-size inputs, bit-flipped ciphertexts in either KEM
  half) with the `HybridKEM` boundary switched from precondition traps to
  thrown errors; constant-time FIPS 203 implicit-rejection comparison in
  `MLKEM768.decaps`; the audit lives in `docs/CRYPTO_REVIEW.md`.

- **Browser UX debt**: history-backed omnibox suggestions dropdown (ranked
  by match tier + frequency + recency; non-activating panel, arrow keys and
  escape handled in the field editor so the omnibox never loses focus);
  favicons in the tab strip (page-declared icon or `/favicon.ico`, fetched
  with a cookie-free ephemeral session and cached per container so icon
  fetches can never leak container identity); tab drag-reorder in the strip
  (threshold drag, committed on mouse-up through `TabManager.move`); and
  **Private Windows** (⌘⇧N — every tab ephemeral, dark-tinted window,
  excluded from session restore and window-frame autosave).

### Changed
- Repository moved to the **8b-is** organization
  (`github.com/8b-is/qwave`); the Sparkle feed URL points at the new home.
- `CFBundleVersion` scheme is now `major*10000 + minor*100 + patch`
  (0.3.0 → 300), enforced against the tag by the release workflow — this is
  the value Sparkle compares between installs.

## [0.2.0] - 2026-08-12

### Added
- **WebExtensions MV3 Engine**: `browser.*` JavaScript API bridge injected into every page (`browser.tabs`, `browser.storage.local`, `browser.runtime.sendMessage`), file-backed extension storage, manifest registry, and `NSPopover` extension popups with a toolbar entry point.
- **Post-Quantum VPN (Stage B)**: pure-Swift FIPS 202 Keccak/SHAKE, FIPS 203 ML-KEM-768 (NTT, basemul, implicit rejection), and Classic McEliece 348864 (Goppa codes, batch inversion, key-equation decoding) verified against an independent Python oracle; dual-KEM hybrid PSK negotiation with the relay's ephemeral-peer service, wired through `TunnelSessionConfig.quantumResistant`.
- **uBlock Origin & EasyList Rule Compiler**: uBO/AdGuard network-filter syntax → `WKContentRuleList` JSON (anchored hosts, resource types, `$domain=`, third-party, exceptions via `ignore-previous-rules`), plus an ETag-cached remote blocklist updater.
- **Menu Bar VPN Widget**: live tx/rx throughput in the status bar (polled from the tunnel provider's runtime config) and a one-click country/relay server switcher built from the Mullvad relay list.

## [0.1.0] - 2026-08-12

### Added
- **WebKit-Native Browser Engine**: Thin AppKit shell + SwiftUI control panes backed by WebKit `WKWebView`.
- **Firefox-Style Container Universes**: Per-container isolated `WKWebsiteDataStore(forIdentifier:)` and ephemeral non-persistent burner tabs.
- **Brave Shields**: Curated 51-rule `WKContentRuleList` blocking, per-site JS toggles, and HTTPS-First upgrader.
- **Energy Governor & Hibernation**: `TabHibernator` tab destruction and state capture to minimize WebKit memory footprint.
- **Safari SPI Feature Flags**: Safe `responds(to:)` guarded `_WKFeature` reflection.
- **Mullvad VPN Integration (Stage A)**: WireGuardKit system extension architecture (`NETunnelProviderManager`).
- **SQLite Persistence**: Raw WAL-mode SQLite database for history, bookmarks, and sessions.
