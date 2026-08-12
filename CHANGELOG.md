# Changelog

All notable changes to Qwave will be documented in this file.

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
