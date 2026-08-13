# 07 · Security, Crypto & VPN

| Package | Version | Verdict | Qwave module |
|---------|---------|---------|--------------|
| [swift-crypto](swift-crypto.md) | 4.5.1 (5.0.0-beta.4 in prerelease) | 🟢 Adopt | `VPNKit/DeviceKeyManager` |
| [WireGuardKit](wireguardkit.md) | pinned commit `2fec12a6` | 🟢 Adopt (already in) | `Sources/PacketTunnel` |
| [swift-certificates](swift-certificates.md) | 1.19.4 (Jul 28) | 🔵 Trial | `VPNKit`, future pinning |
| [mullvadvpn-app](mullvadvpn-app.md) | 2026.3 stable / 2026.4-beta2 | 🔴 Hold (as a dependency) | Reference only |

---

## The stakes

This is the category where being wrong is expensive. `VPNKit` handles account tokens, device
private keys, and relay selection; `QwaveSupport/SecretStore.swift` holds them in the Keychain;
`PacketTunnel` carries the user's actual traffic.

Two Qwave-specific rules apply on top of the general ones in the [research README](../README.md):

1. **Key material never leaves the Keychain in plaintext.** `SecretStore` is the only path.
   `SecretStoreTests` exists to keep it that way.
2. **Fail closed.** A VPN that fails open is worse than no VPN, because the user believes they
   are protected. Any change to `TunnelManager` or `PacketTunnelProvider` must be evaluated for
   what happens on failure, not just on success.

## What is already right

Qwave's existing choices in this category are sound and should not be churned:

- **WireGuard pinned to a specific commit** (`2fec12a6e1f6e3460b6ee483aa00ad29cddadab1`). Pinning
  a VPN implementation to a reviewed revision is correct practice, not technical debt.
- **`NETunnelProviderManager` + system extension.** The supported architecture, with the
  packet-level work isolated in its own process.
- **Keychain for secrets**, with a dedicated module and dedicated tests.

## Where the gaps are

- **[swift-crypto](swift-crypto.md)** — `DeviceKeyManager` handles Curve25519 keys for WireGuard.
  Whether that goes through CryptoKit, swift-crypto, or hand-rolled code determines the quality
  of the most security-sensitive code in the app.
- **[swift-certificates](swift-certificates.md)** — Qwave has no certificate pinning today. For
  the Mullvad API, pinning is a meaningful hardening step against a compromised or coerced CA.
- **Post-quantum.** `VPNKit/EphemeralPeerNegotiator.swift` exists, which suggests Mullvad's PQ
  ephemeral peer exchange is at least partly modelled. swift-crypto 5.0's prerelease line is
  where the primitives for that kind of work are landing.
