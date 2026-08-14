# Security policy

Qwave is privacy-oriented browser software, not an anonymity system. Its
security claims are limited to the boundaries described here and in
[docs/NETWORK.md](docs/NETWORK.md). If you find a vulnerability, please report
it privately before opening an issue.

## Reporting a vulnerability

Use a [GitHub Security Advisory](https://github.com/8b-is/qwave/security/advisories/new).
If that channel is unavailable, email `peter.lodri@gmail.com` with
`[qwave security]` in the subject. Include the affected version/commit,
platform, reproduction steps, impact, and any proof of concept that can be
shared safely.

We aim to acknowledge reports within 72 hours. We will coordinate a fix and
credit reporters unless they prefer to remain anonymous. Do not include live
credentials, private keys, or other users' data in a report.

Supported releases: the latest tagged release on `main`. There are currently no
backport branches or guaranteed support window for older tags.

## Threat model

### Assets

- Container cookies, web storage, service workers, and cached site data.
- Local history, bookmarks, sessions, and encrypted MemoryWave records.
- The WireGuard device private key and negotiated tunnel PSKs.
- Release signing keys, Sparkle appcast integrity, and update provenance.
- The confidentiality and integrity of traffic between the device and VPN relay.

### Adversaries considered

- **Malicious web content.** WebKit process isolation, separate container data
  stores, native content rules, canonical host identity, and per-site
  JavaScript policy reduce cross-site and policy-bypass risk.
- **On-path network attackers.** App-owned API traffic uses HTTPS and the
  Mullvad client uses certificate pinning. The optional VPN protects traffic
  through WireGuard; the Stage-B PSK path combines ML-KEM-768 and Classic
  McEliece and fails closed when quantum resistance is enabled.
- **Update-channel attackers.** Release artifacts are signed/notarized when
  the distribution secrets and Apple approvals are available. Sparkle
  appcasts use Ed25519 signatures; the private signing seed is not committed.
- **Harvest-now/decrypt-later attackers.** The Stage-B goal is to require
  compromise of both KEM legs in addition to the classical WireGuard material.

### Explicitly out of scope

- A compromised local account, malware with root access, or a malicious signed
  process running on the Mac.
- Mullvad relay compromise or a relay that can observe traffic metadata.
- Full anonymity against websites, DNS operators, Apple/WebKit services, or
  the VPN provider.
- Timing side-channel resistance of the current Classic McEliece decoder; see
  [docs/CRYPTO_REVIEW.md](docs/CRYPTO_REVIEW.md).
- Guaranteed zeroization of Swift `Data` values. Daily key rotation limits
  exposure, but Swift storage lifetime is not a hard zeroization primitive.

## Isolation boundaries

### Web content and containers

Each persistent container uses its own `WKWebsiteDataStore` identifier. Burner
tabs use non-persistent stores and are omitted from history/session restore.
Removing a container deletes its WebKit store and associated local rows. This
is isolation from accidental cross-container state, not protection from a
compromised macOS account or WebKit itself.

### Application state

QwaveKit is compiled in Swift 6 language mode with complete strict concurrency.
Actors own SQLite connections, prepared statements, and MemoryWave mutations;
sendable value types cross into UI tasks. The NetworkExtension provider has a
narrow SDK compatibility annotation for its legacy mutable callback surface.
That annotation is confined to the provider and does not make arbitrary
application objects safe to share across actors.

### Secrets

The device private key lives in the shared Keychain access group. The tunnel
configuration passed through `providerConfiguration` contains connection
parameters but not key material; tests enforce this boundary. Remote MemoryWave
providers are disabled until the user configures one and supplies credentials.

## Network and telemetry

Qwave distinguishes three traffic classes:

1. **Qwave-owned requests** — update checks, Mullvad API calls, explicit remote
   inference, favicon fetches, and requested document loads. Their hosts and
   triggers are listed in [docs/NETWORK.md](docs/NETWORK.md).
2. **Page traffic** — requests made because the user navigated to a page. WebKit
   and the page control this class; shields can block many third-party loads.
3. **WebKit service traffic** — engine-level anti-fraud and speculative
   behavior. Qwave documents known behavior but cannot claim to control every
   request Apple WebKit may make.

Qwave has no product analytics or behavioral telemetry. Category-A hosts are
checked by `EgressGuardTests`; adding a new app-owned host requires an allowlist
change, documentation, and tests.

## Cryptography and release integrity

The PostQuantum module has independent known-answer fixtures and negative tests.
The crypto self-audit, limitations, and review checklist live in
[docs/CRYPTO_REVIEW.md](docs/CRYPTO_REVIEW.md). Do not describe the hybrid path
as a formal certification or as a replacement for a complete cryptographic
review.

Release signing details, entitlements, Sparkle key handling, and the current
Network Extension approval gap are documented in [docs/SIGNING.md](docs/SIGNING.md).
Unsigned CI artifacts are development/test artifacts and must not be described
as notarized releases.

## Security changes

Security-sensitive changes should include:

- a focused regression test or known-answer vector;
- an explicit threat-model or data-flow update when a boundary changes;
- a review of actor/sendability annotations and any new unchecked boundary;
- egress allowlist and [network documentation](docs/NETWORK.md) updates for
  new Qwave-owned connections;
- a release/signing note when distribution or update trust changes.
