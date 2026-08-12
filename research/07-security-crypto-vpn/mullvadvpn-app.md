# mullvadvpn-app (`mullvad/mullvadvpn-app`)

| | |
|---|---|
| **Repo** | https://github.com/mullvad/mullvadvpn-app |
| **Version** | **2026.3** stable (Jun 15) · **2026.4-beta2** (Aug 10) |
| **License** | GPL-3.0 |
| **Platforms** | macOS, Windows, Linux, iOS, Android |
| **Apple Silicon** | Native |
| **Verified** | 2026-08-12 |

---

## What it is

Mullvad's own VPN client, open source across every platform they ship. The macOS and iOS clients
are Swift, and they implement exactly what `VPNKit` is implementing: account management, device
registration, relay selection, tunnel configuration, DNS handling, and post-quantum ephemeral
peer exchange.

It is the **reference implementation** for Qwave's entire VPN feature.

## Why it matters for Qwave

**As documentation, not as a dependency** — and the licence makes that distinction mandatory.

`Packages/QwaveKit/Sources/VPNKit/` maps almost file-for-file onto problems Mullvad has already
solved in production:

| Qwave file | What the reference implementation shows |
|------------|----------------------------------------|
| `MullvadAPIClient.swift` | The actual API endpoints, request shapes, and error semantics |
| `RelaySelector.swift` | Relay filtering, weighting, and failover behaviour |
| `DeviceKeyManager.swift` | Key rotation cadence and device registration lifecycle |
| `EphemeralPeerNegotiator.swift` | Post-quantum ephemeral peer exchange |
| `TunnelSessionConfig.swift` | WireGuard config generation, DNS and MTU handling |
| `TunnelManager.swift` | State machine, reconnection, and network-change handling |

The 2026.4-beta2 note — a split-tunnelling parse error on macOS 27 — is itself useful
intelligence: it says split tunnelling on macOS 27 is an area in flux, worth knowing before
Qwave's tunnel meets that OS.

### The relay list is the interesting problem

`RelaySelectorTests` and the `relays.json` fixture in `VPNKitTests` show Qwave already models
this. The hard parts — weighting by load, filtering by protocol and port, failover ordering,
handling a stale list — are all decided in the reference implementation, and those decisions are
worth understanding rather than re-deriving.

## The licence boundary

**GPL-3.0.** This is the whole reason this note is a Hold.

| Action | Permitted for a non-GPL app |
|--------|----------------------------|
| Read the code to understand the protocol | ✅ Yes |
| Learn API endpoints and request shapes | ✅ Yes — those are facts about a service, not code |
| Depend on it as a package | ❌ No |
| Copy code into `VPNKit` | ❌ No |
| Copy its structure closely enough to be derivative | ❌ Legally risky |

Qwave is MIT-licensed. Copying GPL-3.0 code into it is a licence violation, and "we reworded it"
is not a defence for a close transliteration.

The correct posture: **read for understanding, implement independently**. This is a normal and
legitimate way to build against a documented protocol — and Mullvad also publishes API
documentation, which is the safer primary source where it covers the need.

## Apple Silicon notes

Nothing Qwave-relevant. Their macOS client is native and their Swift code demonstrates
`NEPacketTunnelProvider` patterns that apply equally here — but those patterns are documented by
Apple, which is the citable source.

## Adoption sketch

None. As a working practice:

1. Prefer **Mullvad's published API documentation** over their source when it covers the need.
2. When reading source to understand behaviour, note the *behaviour* — key rotation interval,
   failover ordering — not the implementation.
3. Do not keep a copy of their source in this repository, even in a scratch directory.
4. Write `VPNKit` code from the specification, and cover it with Qwave's own tests.

## Risks

- **Licence contamination is the risk.** GPL-3.0 code in an MIT app is a real legal problem, and
  it is easiest to create accidentally while "just checking how they did it".
- **Protocol drift.** Mullvad's API can change. Their release notes are a useful early warning —
  the split-tunnelling item above is an example.
- **Anchoring.** Their implementation targets their full product surface. Qwave needs a subset,
  and copying the structure imports complexity that does not apply here.

## Verdict

🔴 **Hold as a dependency — 🟢 invaluable as a reference.**

Every hard problem in `VPNKit` has been solved in this repository already, in Swift, in
production. That makes it the single most useful document for the VPN work — and the GPL-3.0
licence makes it strictly a document.

**The rule worth recording:** `VPNKit` contains no code derived from mullvadvpn-app. Behaviour is
implemented from Mullvad's published API documentation and from Apple's Network Extension
documentation, and is covered by Qwave's own tests.
