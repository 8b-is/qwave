# Changelog

All notable changes to Qwave will be documented in this file.

## [0.1.0] - 2026-08-12

### Added
- **WebKit-Native Browser Engine**: Thin AppKit shell + SwiftUI control panes backed by WebKit `WKWebView`.
- **Firefox-Style Container Universes**: Per-container isolated `WKWebsiteDataStore(forIdentifier:)` and ephemeral non-persistent burner tabs.
- **Brave Shields**: Curated 51-rule `WKContentRuleList` blocking, per-site JS toggles, and HTTPS-First upgrader.
- **Energy Governor & Hibernation**: `TabHibernator` tab destruction and state capture to minimize WebKit memory footprint.
- **Safari SPI Feature Flags**: Safe `responds(to:)` guarded `_WKFeature` reflection.
- **Mullvad VPN Integration (Stage A)**: WireGuardKit system extension architecture (`NETunnelProviderManager`).
- **SQLite Persistence**: Raw WAL-mode SQLite database for history, bookmarks, and sessions.
