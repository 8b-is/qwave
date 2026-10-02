# Qwave Privacy Policy

Last updated: 2026-10-03

Qwave is privacy-oriented software: the browser stores your data on your
device and phones home as little as technically possible. This policy says
precisely what leaves the machine and what does not; the mechanical
guarantee lives in [docs/NETWORK.md](docs/NETWORK.md) (the Category-A
egress inventory) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## What Qwave stores, and where

Everything below is stored **on your device only** — there is no Qwave
account, no cloud sync operated by us:

- Browsing history, bookmarks, favicons, and sessions — SQLite in
  `~/Library/Application Support/Qwave` (macOS) / the app's Application
  Support container (iOS), per-container (profile-scoped).
- Saved logins and passkeys — your OS / iCloud Keychain (your Apple
  account's own sync, not ours).
- "Memory Wave" memories and nibbles — encrypted at rest with a key in your
  Keychain; sealed as ciphertext on disk.
- Settings — `UserDefaults` in the app's own domain.

## What leaves your device

| Activity | Sent where | When | Off by default? |
|---|---|---|---|
| Omnibox autocomplete | `ac.ecosia.org` (Ecosia) or `duckduckgo.com` — the engine you chose | Only while you type, and only if you enabled search suggestions | **Yes** — on-device suggestions (history, bookmarks, open tabs) need no network |
| Auto-update check (macOS) | `github.com` (the Sparkle appcast) | After you consent to update checks; manual "Check for Updates" always works | **Yes** — asks before any background check |
| Memory Wave remote AI | The OpenAI-compatible endpoint **you** configured (default: `api.x.ai`) | Only when you explicitly Summarize/Ask with a remote provider configured | **Yes** — local-first; the page text you ask about is what is sent |
| Shields blocklist | — | Nothing: the blocklist ships as a committed snapshot | n/a — no runtime fetch |

Qwave does **not** ship telemetry, analytics, crash reporters, or
advertising identifiers of any kind. `qwave://diagnostics` is local
(MetricKit data on your machine); the optional debug export scrubs URLs
before anything is written.

## What pages see

Web pages you visit see what any browser shows them. Qwave's shields
blocklist compiles locally and runs in WebKit. The VPN layer was removed
entirely — Qwave does not tunnel your traffic.

## The iPhone lane

The same policy, the same Category-A allowlist, enforced by the same Rust
core. Search suggestions on iOS are gated by the same opt-in and the same
egress decision.

## Questions

The network inventory with exact endpoints and conditions:
[docs/NETWORK.md](docs/NETWORK.md). Source: <https://github.com/8b-is/qwave>.
