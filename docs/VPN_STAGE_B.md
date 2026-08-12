# VPN Stage B — Quantum-Resistant Tunnels

Stage A ships classic WireGuard (Curve25519 + ChaCha20-Poly1305). Stage B adds
Mullvad's **quantum-resistant tunnels**: a post-quantum key exchange that
derives a WireGuard *preshared key* (PSK), so that recorded traffic cannot be
decrypted later by a quantum computer breaking Curve25519 (harvest-now,
decrypt-later defense). WireGuard's PSK slot is exactly designed for this: it
mixes a symmetric secret into the handshake, and symmetric crypto is not
meaningfully weakened by quantum attacks.

## How Mullvad's exchange works (reference: mullvadvpn-app)

1. Bring the tunnel up with a **classic** handshake first.
2. *Inside* the tunnel, talk to the relay's ephemeral-peer service
   (gRPC on the in-tunnel gateway, port 1337 in mullvadvpn-app's
   `talpid-tunnel-config-client`).
3. Run **two KEMs** and mix the results:
   - **ML-KEM-1024** (CRYSTALS-Kyber, NIST-standardized lattice KEM)
   - **Classic McEliece 460896f** (code-based, very conservative, huge keys)
   The PSK is derived by hashing the two shared secrets together; an attacker
   must break *both* (and Curve25519) to recover traffic.
4. The client requests a new ephemeral peer with `psk` enabled, then swaps the
   WireGuard configuration to install the PSK (and, on daita-capable relays,
   the daita machine parameters) and re-handshakes.

## Where it plugs into Qwave

The seam is already in place and exercised:

- `VPNKit.EphemeralPeerNegotiating` — protocol with
  `negotiatePresharedKey(config:) async throws -> PresharedKeyMaterial?`.
- `TunnelSessionConfig.quantumResistant: Bool` — carried through
  providerConfiguration; UI toggle exists in the VPN pane.
- `PacketTunnelProvider.startTunnel` — already calls the negotiator before
  `WireGuardAdapter.start` and installs the returned PSK on the peer.
  Stage A's `NoopEphemeralPeerNegotiator` returns nil → classic WireGuard.

## Stage B implementation sketch

1. **Two-phase tunnel start** in `PacketTunnelProvider`: start classic (as
   today), then negotiate in-tunnel, then `adapter.update(tunnelConfiguration:)`
   with the PSK-carrying peer. (The current code negotiates *before* start,
   which is correct for the noop; the real negotiator needs the tunnel up
   first — move the call between `start` and a follow-up `update`.)
2. **KEM implementations**: bind Mullvad's Rust crates
   (`talpid-tunnel-config-client` uses `classic-mceliece-rust` + `ml-kem`)
   via a small C FFI static library, or port to Swift using liboqs. The
   pragmatic path is reusing Mullvad's `mullvad-wireguard-go` fork the same
   way their macOS app does.
3. **Protocol**: gRPC `EphemeralPeerService` — request contains the WG public
   key + KEM public keys; response carries ciphertexts. Derive PSK =
   HKDF/Blake2 over both shared secrets (match mullvadvpn-app's derivation
   exactly; see `talpid-tunnel-config-client/src/lib.rs`).
4. **Rekey cadence**: Mullvad rotates the ephemeral peer daily; schedule via
   the extension's sleep/wake hooks.

## Verification plan

- Unit-test the PSK derivation against test vectors extracted from
  mullvadvpn-app.
- Integration: connect with `quantumResistant` on, then check
  `wg`-style runtime config (`TunnelManager.requestStats()`) reports a
  `preshared_key` line (the adapter's `getRuntimeConfiguration` exposes it).
- Mullvad's own "Am I using quantum-resistant tunnels?" indicator on
  mullvad.net/check reflects the relay-side view.
