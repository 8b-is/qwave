# Qwave Privacy Policy

Last updated: 2026-10-14

This policy describes Qwave's macOS and iPhone/iPad features. Availability
depends on your app version, platform and system capabilities. Local processing
does not mean the browser is offline: websites, search engines and optional
remote AI providers receive the requests described below. See
[docs/NETWORK.md](docs/NETWORK.md) for the app's network inventory.

## What Qwave stores, and where

Qwave keeps browser data in local app storage and does not operate a Qwave
account or cloud-sync service. Apple Keychain synchronization and optional
remote AI processing are described separately below.

- Browser data — local app storage, with website cookies and other site data
  managed by WebKit. Features and storage controls differ by platform.
- Saved website passwords (macOS) — OS Keychain. Qwave marks these password
  items for iCloud Keychain synchronization when available through your Apple
  account. It also registers service and account metadata with the system's
  AutoFill index; the password stays in Keychain.
- "Memory Wave" memories and nibbles — encrypted at rest with a key in your
  Keychain; sealed as ciphertext on disk.
- Settings — `UserDefaults` in the app's own domain.

On macOS, Memory Wave can save pages you explicitly pin. Its optional Remember
everything setting captures additional browsing locally; private and ephemeral
tabs are excluded from that capture path. On iPhone and iPad, Remember this page
saves the page title, address and a short hostname description. Saved-page
suggestions reopen the original address. This iPhone/iPad path does not
automatically capture every page or call a remote AI provider.

Qwave's credential-provider extension is a macOS feature. The iPhone/iPad app
does not include that extension. Website passkey availability depends on the
platform and browser capabilities; see [passkey coverage and limits](docs/BROWSER-PASSKEYS.md).

## What leaves your device

| Activity | Sent where | When | Off by default? |
|---|---|---|---|
| Omnibox autocomplete | `ac.ecosia.org` (Ecosia) or `duckduckgo.com` — the engine you chose | Only while you type, and only if you enabled search suggestions | **Yes** — on-device suggestions (history, bookmarks, open tabs) need no network |
| Auto-update check (direct-download macOS builds) | `github.com` (the Sparkle appcast) | After you consent to update checks, or when you manually check | **Yes** — asks before any background check; App Store builds receive updates through Apple instead |
| Memory Wave remote AI (macOS) | The OpenAI-compatible endpoint **you** configured (default: `api.x.ai`) | Only when you explicitly Ask, summarize a page, or summarize a timeline with a remote provider configured | **Yes** — remote Ask/page summaries send your prompt and any included current page text; timeline summaries send saved titles, times, and site hostnames without saved page bodies |
| Shields blocklist | — | Nothing: the blocklist ships as a committed snapshot | n/a — no runtime fetch |

## Diagnostics and beta feedback

The macOS diagnostics component stores MetricKit reports locally and displays
them on the read-only `qwave://diagnostics` page. This component has no Qwave
telemetry upload endpoint. TestFlight and Apple's crash-reporting features are
separate services governed by Apple's terms and your settings. Feedback you
choose to submit can include screenshots, diagnostic information and comments.

## Page translation

Your reading language, automatic-translation choice, and site/language exceptions
are stored in local settings. On supported systems (macOS 15+ / iOS 18+),
Qwave uses Apple's Translation framework to process page text on-device.
Automatic translation is enabled initially and can be disabled in Language.
Apple may prompt to download the required language models; this is OS-managed
network activity, not a Qwave translation-server upload.

Qwave has no remote translation provider or cloud fallback. If local translation
is unavailable, it keeps the original page. Show original restores translated
text; form values, password fields and editable content are excluded. See
[preferred reading language](docs/preferred-reading-language.md) for coverage
and limits. This feature is separate from optional remote Memory Wave AI.

## What pages see

Web pages you visit see what any browser shows them. Qwave's shields
blocklist compiles locally and runs in WebKit. The VPN layer was removed
entirely — Qwave does not tunnel your traffic.

## Your choices

Network search suggestions are opt-in on both platforms. On macOS, you can keep
the remote AI provider disabled and turn off Remember everything. On iPhone and
iPad, Clear saved Memory Waves removes the saved Memory Wave records. Turning
a feature off does not necessarily erase data already stored.

Qwave has no website-password deletion screen. Deleting a login outside Qwave
does not guarantee that its system AutoFill suggestion metadata is removed.
Memory Wave clearing does not delete website passwords.

## Questions

The network inventory with exact endpoints and conditions:
[docs/NETWORK.md](docs/NETWORK.md). Source: <https://github.com/8b-is/qwave>.
