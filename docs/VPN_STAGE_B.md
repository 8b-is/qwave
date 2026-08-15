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
   - **ML-KEM-768** (FIPS 203 standardized lattice KEM / CRYSTALS-Kyber)
   - **Classic McEliece 348864** (code-based conservative McEliece; Mullvad reference also supports 460896f)
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

---

## Stage B as shipped in v0.2.0

The Stage B seam is now implemented end-to-end:

- **`PostQuantum` module** (pure Swift, zero dependencies):
  - FIPS 202 Keccak/SHAKE (own permutation implementation, verified against
    Python hashlib vectors).
  - **ML-KEM-768** per FIPS 203: NTT with ζ=17 twiddle table, basemul
    NTT-domain multiplication, CBD, implicit rejection. Verified against an
    independent Python oracle (schoolbook + NTT formulations) via committed
    known-answer vectors.
  - **Classic McEliece 348864** (m=12, n=3488, t=64, f=0x1053): binary
    Goppa codes, batch inversion for syndrome columns, systematic generator
    via GF(2) RREF, and key-equation decoding (σ′ ≡ S·σ mod g solved as a
    linear system — the reference's FFT decoder solves the same equation).
    Decapsulation re-checks the codeword (zero syndrome) before returning a
    key, so decoding failures throw instead of producing a wrong PSK.
  - **`HybridKEM`**: ML-KEM-768 ‖ Classic McEliece 348864 with a domain-
    separated PSK = SHAKE256("qwave/pq-psk/v1" ‖ ss₁ ‖ ss₂, 32).
- **`MullvadQuantumPeerNegotiator`** (VPNKit): generates a fresh hybrid key
  pair per session, posts the encapsulation keys to the relay's in-tunnel
  ephemeral-peer service (JSON over the tunnel gateway, port 1337),
  decapsulates the relay's ciphertext bundle, and returns the PSK.
  `PacketTunnelProvider` installs it on the WireGuard peer; any failure
  falls back to classic WireGuard.
- **Interop note**: byte-level conformance with mullvadvpn-app's exact
  gRPC wire format is a follow-up (Stage B.5); the KEM primitives are
  standard-conformant (ML-KEM-768 is FIPS 203; McEliece 348864 follows the
  NIST round-3 parameter set), and the transport carries the same material
  (WG pubkey, KEM keys, ciphertext bundle) in a versioned JSON envelope.
