# Security Policy

## Reporting a vulnerability

Please report vulnerabilities privately via
**[GitHub Security Advisories](https://github.com/8b-is/qwave/security/advisories/new)**
("Report a vulnerability" on the repo's Security tab). If that channel is
unavailable, email `peter.lodri@gmail.com` with `[qwave security]` in the
subject. You should receive an acknowledgement within 72 hours. Please do
not open public issues for security reports.

Supported: the latest tagged release on `main`. There are no backport
branches.

## Threat model (what Qwave defends, and against whom)

Qwave is a WebKit-native browser whose differentiating claims are
per-container isolation, content shielding, and a quantum-resistant VPN
tunnel. The model below is what the engineering gates actually enforce.

**Assets**: browsing history/bookmarks/sessions (local SQLite), container
cookie/storage universes, the WireGuard device private key and daily
ephemeral PSKs (Keychain + tunnel process memory), the Sparkle update
channel, the user's traffic-to-relay confidentiality.

**Adversaries considered**:

- *Malicious web content* — confined by WebKit's process isolation and
  per-container `WKWebsiteDataStore`s; host-keyed policy decisions derive
  from the WHATWG-canonical host (the identity WebKit loads), closing the
  Foundation-vs-WebKit parser-divergence bypass class (`URLIdentity`,
  since v0.3.0).
- *Network attackers (on-path)* — app-level HTTP rides `URLSession` and
  follows the system routing table through the tunnel when up; no raw
  socket clients are permitted in the codebase (standing rule). Tunnel PSK
  negotiation is hybrid ML-KEM-768 + Classic McEliece; a negotiation
  failure with quantum resistance enabled fails closed (no silent classic
  fallback, since v0.3.0).
- *Update-channel attackers* — releases are EdDSA-signed (Sparkle 2); the
  private seed exists only in CI secrets and the maintainer's machine;
  unsigned builds are never published into the appcast. A compromised
  download host cannot forge an update without that key.
- *Harvest-now-decrypt-later* — the point of Stage B: tunnel PSKs require
  breaking both KEM legs plus Curve25519.

**Explicitly out of scope**: a compromised local machine or root attacker;
timing side channels against the McEliece decoder (documented as
variable-time in `docs/CRYPTO_REVIEW.md` — the decoder never processes
attacker-chosen ciphertexts); Mullvad relay compromise (relay selection
trusts Mullvad's signed API); memory zeroization guarantees for Swift
`Data` (documented limitation, mitigated by daily key rotation).

## Crypto review

The self-audit of the PostQuantum module (constant-time findings, key
lifetime, review checklist for crypto changes) lives in
[docs/CRYPTO_REVIEW.md](docs/CRYPTO_REVIEW.md). KAT vectors are generated
from an independent Python oracle, never from the Swift implementation
under test.
