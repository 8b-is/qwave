# swift-crypto (`apple/swift-crypto`)

| | |
|---|---|
| **Repo** | https://github.com/apple/swift-crypto |
| **Version** | **4.5.1** (Jul 16) · **5.0.0-beta.4** (Aug 7) in prerelease |
| **License** | Apache 2.0 |
| **Platforms** | All Swift platforms |
| **Apple Silicon** | Uses CryptoKit's hardware-accelerated paths on Darwin |
| **Verified** | 2026-08-12 |

---

## What it is

An open-source implementation of a substantial portion of Apple's CryptoKit API, available on
every Swift platform. Coverage spans key exchange, key derivation, encryption/decryption,
hashing, message authentication, and digital signatures.

On Darwin it largely defers to the system's CryptoKit implementation, which means the
hardware-accelerated paths on Apple Silicon are used rather than bypassed. The API is the same
either way, so code written against it is portable without being slower.

A **5.0.0 major is in beta** (beta.4 as of early August), while 4.5.1 is the current stable.

## Why it matters for Qwave

`VPNKit/DeviceKeyManager.swift` manages the device's WireGuard key pair. WireGuard uses
**Curve25519** for its handshake, and how those keys are generated, stored, and used is the most
security-critical code in the application.

```swift
import Crypto

// Generation — cryptographically secure by construction
let privateKey = Curve25519.KeyAgreement.PrivateKey()
let publicKey  = privateKey.publicKey.rawRepresentation   // → registered with Mullvad

// Never touch the raw private key outside SecretStore
try SecretStore.shared.store(privateKey.rawRepresentation, for: .deviceKey)
```

The types matter as much as the algorithms. `Curve25519.KeyAgreement.PrivateKey` makes it hard
to accidentally log, serialise, or transmit a private key — the failure mode that turns a
correct protocol into a compromised one.

### The CryptoKit question

On a macOS-only, Apple Silicon-only app, `import CryptoKit` gives the same API with **zero
dependencies**. So why consider the package at all?

| | CryptoKit | swift-crypto |
|--|-----------|--------------|
| Dependency | None | One (Apache 2.0, Apple-maintained) |
| Availability | macOS 10.15+ | Any Swift platform |
| API surface | Smaller | Superset — includes primitives CryptoKit omits |
| Testability | Harder to test in isolation | Same API, testable off-device |

For Qwave's current needs, **CryptoKit is sufficient and preferable** — fewer dependencies is a
security property in itself for a sovereign browser. swift-crypto earns its place when a
required primitive is missing from CryptoKit.

`VPNKit/EphemeralPeerNegotiator.swift` is the file that could change that answer. Mullvad's
post-quantum ephemeral peer exchange uses primitives beyond the classical set, and if that work
advances, swift-crypto's broader surface — particularly on the 5.0 line — becomes the reason to
adopt.

## Apple Silicon notes

CryptoKit and swift-crypto both use Apple Silicon's cryptographic acceleration on Darwin: the
dedicated AES instructions and SHA extensions in the ARMv8 crypto extensions. Curve25519 runs in
constant time on optimised assembly paths.

The practical consequence for Qwave: handshake and key operations are fast enough to be
invisible. There is no performance argument for cutting corners here, which removes the usual
excuse for hand-rolled crypto.

## Adoption sketch

Prefer CryptoKit today:

```swift
import CryptoKit    // no dependency, same types, macOS-native
```

Move to swift-crypto only when a specific primitive requires it:

```swift
.package(url: "https://github.com/apple/swift-crypto", from: "4.5.1")
```

```swift
import Crypto   // drop-in: the API matches CryptoKit
```

The migration is close to mechanical because the APIs align by design — which is a good reason
not to pre-emptively adopt.

## Risks

- **5.0.0 is in beta.** Do not ship a beta crypto library in the module handling VPN keys. Stay
  on 4.5.1 if the package is adopted at all.
- **Two crypto APIs.** Mixing `CryptoKit` and `Crypto` imports across modules invites confusion.
  Pick one per module and be consistent.
- **Never hand-roll.** The genuine risk in this category is neither package — it is someone
  implementing key derivation or nonce handling manually because a library "didn't have quite the
  right shape". Both options here are correct; hand-rolled crypto is not.
- **Key lifetime.** Neither library protects against a private key being written somewhere it
  should not be. `SecretStore` plus `SecretStoreTests` is what enforces that, and it is where
  review effort belongs.

## Verdict

🟢 **Adopt — CryptoKit now, swift-crypto when a primitive demands it.**

The right cryptographic API for `DeviceKeyManager` is one of these two, and they are the same
API. Use CryptoKit while the requirements stay classical; swift-crypto is the pre-approved
escape hatch for `EphemeralPeerNegotiator`'s post-quantum work, adopted at **stable 4.5.1**, not
the 5.0 beta.

**The rule worth recording:** no hand-rolled cryptography in `VPNKit`, ever. If a primitive
appears to be missing, the answer is swift-crypto, not an implementation.
