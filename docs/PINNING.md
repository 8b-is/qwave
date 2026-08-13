# Certificate pinning: api.mullvad.net

**Scope:** Qwave pins the TLS certificate chain of `api.mullvad.net` only —
the Mullvad control API that serves the relay list and account/device data.
For a privacy VPN, a mis-issued certificate on the relay-list endpoint is a
position from which to feed a user a manipulated relay set, so this one
endpoint is worth pinning. Nothing else is pinned. **Web content
certificates are explicitly out of scope** — WebKit validates those and its
verdict governs whether a page loads; a second opinion there would be a
liability, not a feature.

## Rotation design (written before the pin was implemented)

Pinning without a rotation story bricks the app. Here is the story.

### What api.mullvad.net actually serves (verified 2026-08-13)

```
leaf:         CN=<per-server>.mullvad.net   ← Let's Encrypt, 90-day validity,
                                              hostname varies by API server
intermediate: Let's Encrypt "YE2"          ← LE rotates these
root:         ISRG Root X2  (chains to X1)  ← stable for years
```

Leaf and intermediate pinning are therefore **not viable**: the leaf renews
every ~60–90 days and differs per API server, and Let's Encrypt rotates its
intermediates and explicitly advises against pinning them. Either would
brick the API on a routine renewal.

### The pin: ISRG roots (the stable anchor)

Qwave pins the **Subject Public Key Info (SPKI) SHA-256** of **both** ISRG
roots:

| Root | Key | SPKI pin (base64) | Valid until |
|---|---|---|---|
| ISRG Root X1 | RSA | `C5+lpZ7tcVwmwQIMcRtPbsQtWLABXhQzejna0wHFr8M=` | 2035 |
| ISRG Root X2 | ECDSA | `diGVwiVYbubAI3RW4hB9xU8e/CH2GnkuvVFZE8zmgzI=` | 2040 |

Both are pinned so Let's Encrypt can serve either an RSA (X1) or ECDSA (X2)
chain without tripping the pin — the live chain currently anchors to X2.
Pinning the **root** means routine leaf/intermediate renewals never affect
the pin; only a root-level change does, and those are rare and pre-announced.

The pin is applied **in addition to** normal system trust evaluation
(hostname, expiry, revocation, chain validity all still enforced by the OS),
not instead of it. A cert must pass the system evaluation **and** chain to a
pinned ISRG root.

### What this protects against, honestly

It constrains `api.mullvad.net` to **Let's Encrypt-issued** certificates,
shrinking the mis-issuance attack surface from every public CA (~150) to
one. It does **not** stop an attacker who can pass Let's Encrypt's own
domain validation for the host (e.g. a sustained BGP/DNS hijack). That is a
partial protection — real against a mis-issuing commercial CA, not absolute.

### Recovery paths (when the pin must change)

1. **ISRG rotates roots.** Rare (X1 → 2035, X2 → 2040) and pre-announced by
   ISRG years ahead. Ship an app update adding the new root's SPKI pin
   before the transition; the dual-pin set means the old pin keeps working
   until then.
2. **Mullvad changes CA family** (leaves Let's Encrypt). This is the residual
   brick risk — it is outside Qwave's control and visibility. Mitigation:
   a CA change is itself a deliberate, announceable event on Mullvad's side;
   Qwave ships an app update with the new anchor. Until that update, the
   Mullvad API (and only the API — browsing and the tunnel itself are
   unaffected) would fail closed. This is disclosed in docs/NETWORK.md.

### Why fail-closed, not fail-open

If the pin does not match, the request fails — Qwave does **not** fall back
to system trust. A fail-open pin provides no security (an attacker just
presents a system-trusted mis-issued cert and the fallback accepts it). The
cost is the residual brick risk above, which the recovery paths bound.

## Updating the pins

The pins are computed from the published ISRG root certificates:

```sh
curl -fsSL https://letsencrypt.org/certs/isrgrootx1.pem \
  | openssl x509 -pubkey -noout \
  | openssl pkey -pubin -outform der \
  | openssl dgst -sha256 -binary | openssl enc -base64
```

They live as constants in `VPNKit/MullvadCertificatePinner.swift`, verified
against the live chain by `VPNKitTests`.
