# Changelog

All notable changes to Qwave will be documented in this file.

## [0.4.3] - 2026-08-13

### Added
- **Memory nibbles**: pages are cut into small tagged markdown files
  (`~/Library/Application Support/Qwave/nibbles/YYYY/MM/*.md`) with YAML
  front matter (`tags`, `url`, wave identity). Recall `#tag` from the start
  page or Ask. Encrypted SQLite still holds the full Cognitive wave.

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
