# PostQuantum constant-time & key-hygiene review

Reviewed 2026-08-13 against the v0.3.0 sources (`Packages/QwaveKit/Sources/
PostQuantum`, `VPNKit`, `Sources/PacketTunnel`). Scope: secret-dependent
timing, secret-dependent memory access, key-material lifetime. This is an
engineering self-audit, not a substitute for external review.

## Threat model context

The hybrid KEM runs **once per tunnel start and once per daily rekey** —
not per packet. There is no remote decapsulation oracle: the only party that
can submit ciphertexts is the relay's ephemeral-peer service, over the
established classic WireGuard tunnel. Classic timing-oracle attacks against
FO-transform KEMs need many adaptive queries with precise timing; Qwave's
usage pattern gives an attacker at most a few observations per day through
network jitter. Local attackers (same machine, shared caches) get more
resolution. Ratings below reflect that.

## Findings

### F1 — ML-KEM re-encryption check was not constant time (fixed in v0.3.0)

`MLKEM768.decaps` previously implemented FIPS 203 implicit rejection as
`if ct2 == ct` — `Data ==` short-circuits at the first differing byte
(timing reveals the position of the first re-encryption mismatch), and the
accept/reject paths were a secret-dependent branch. Both are now
constant-time: byte-wise OR-of-XORs comparison over the full ciphertext,
then branchless masked selection between the `k2` and `z` hash inputs. The
full KAT fixture set was re-run after the change (both the accept path —
honest vectors — and the reject path — `HybridKEMNegativeSuite`'s
deterministic implicit-rejection assertions — pin the outputs).

### F2 — McEliece decoder is inherently variable-time (accepted)

`patterson`, `gfInverse` (extended Euclid), `polyDivMod`, and the
`Set<Int>` of error positions all branch and index on secret data; the
`decodingFailure` throw path returns earlier than a successful decode. This
implementation prioritizes auditability of the Goppa-code math over
constant-time execution; a constant-time Classic McEliece decoder
(bitsliced, as in the reference `vec` implementations) is a rewrite, not a
patch. The hybrid construction means an attacker exploiting decoder timing
must *also* break ML-KEM — and the decoder never processes
attacker-chosen ciphertexts (see threat model).
**Status**: accepted for v0.3.0; documented so nobody mistakes it for
constant-time.

### F3 — Keccak is constant-time (verified)

The permutation is fixed-rotation/XOR/AND on lane words with no
data-dependent branches or table lookups — constant-time by construction on
arm64. Hash *inputs* include secrets (PSK derivation), which is fine.

### F4 — ML-KEM sampling paths (verified, with note)

Matrix expansion (`SampleNTT`-style rejection sampling) operates on the
*public* seed ρ — variable time is harmless. CBD sampling of secret
polynomials is arithmetic-only (no secret-indexed tables). Modular
reduction uses `%` by the constant 3329, which Swift compiles to
multiply-shift on arm64 — no data-dependent division timing.

### F5 — Key-material lifetime (best-effort only)

- The WireGuard device private key crosses from Keychain into provider
  memory (`KeychainSecretStore` → `PrivateKey`) and lives for the tunnel's
  lifetime — unavoidable with the WireGuard control plane.
- KEM session seeds, decapsulation keys and derived PSKs are `Data`
  values: Swift's CoW `Data`/`Array` give **no zeroization guarantee** —
  copies may persist until reclaimed, and `resetBytes` on one copy does not
  reach others. The negotiator holds them only as locals scoped to one
  `negotiatePresharedKey` call (nothing retains them), and ephemeral keys
  rotate daily, bounding the exposure window.
- **Status**: accepted with mitigation-by-scoping. A future pass could move
  secrets into fixed `UnsafeMutableRawBufferPointer` allocations with
  explicit `memset_s` cleanup, at real cost to the pure-Swift auditability
  the module optimizes for.

### F6 — Boundary hardening (fixed in v0.3.0)

`HybridKEM` previously `precondition`ed input sizes — a malformed relay
response could kill the tunnel process. Sizes now throw
(`HybridKEMError.invalidInputSize`), covered by negative KATs
(`HybridKEMNegativeSuite`): truncated keys/ciphertexts throw, ML-KEM-half
bit flips trigger deterministic implicit rejection, McEliece-half bit flips
throw `decodingFailure`.

### F7 — Fail-closed downgrade (fixed in v0.3.0)

`PacketTunnelProvider` previously wrapped negotiation in `try?`: a failed
PSK negotiation silently started classic WireGuard while the UI showed
quantum resistance enabled. Now `negotiateFailClosed` blocks tunnel start
with `QuantumSessionError.downgradeBlocked` (user-visible via
`TunnelManager.lastError`), regression-tested in
`FailClosedNegotiationTests` (written before the provider change). Daily
rekey failures deliberately keep the *existing* PSK — the tunnel stays on
the previous quantum-resistant key, which is a retry situation, not a
downgrade.

## Review checklist for future crypto changes

1. Re-run the full KAT fixture set (`swift test --package-path
   Packages/QwaveKit --filter "PostQuantum"`); regenerate vectors only from
   the independent Python oracle, never from the Swift code under test.
2. New comparisons on secret data: constant-time by default.
3. New public API on the KEM boundary: throws on malformed input, plus a
   negative KAT.
4. Anything touching the provider's negotiation path keeps the fail-closed
   property and its regression tests green.
