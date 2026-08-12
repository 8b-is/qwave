# WireGuardKit (`wireguard/wireguard-apple`)

| | |
|---|---|
| **Repo** | https://github.com/wireguard/wireguard-apple |
| **Version** | **pinned to `2fec12a6e1f6e3460b6ee483aa00ad29cddadab1`** (`AGENTS.md` §4) |
| **License** | MIT |
| **Platforms** | macOS, iOS |
| **Apple Silicon** | `libwg-go.a` built for arm64; the Go runtime is arm64-native |
| **Status in Qwave** | **Already integrated** — `Packages/WireGuardKit`, `Sources/PacketTunnel` |
| **Verified** | 2026-08-12 |

---

## What it is

The official WireGuard implementation for Apple platforms. Three layers:

- **`libwg-go.a`** — the WireGuard Go implementation, compiled as a static library. This is the
  actual protocol: Noise handshake, ChaCha20-Poly1305 transport, peer and timer state.
- **`WireGuardKitC`** — the C shim between Swift and Go.
- **`WireGuardKit`** — the Swift API: `PacketTunnelProvider` integration, configuration parsing,
  and tunnel lifecycle.

## Why it matters for Qwave

It is not a candidate — it is **shipping**. `Packages/WireGuardKit` and
`Sources/PacketTunnel/PacketTunnelProvider.swift` are the Stage A VPN architecture described in
the README. This note exists to record *why the current setup is right* and what to watch.

### The pin is correct practice

`AGENTS.md` pins the exact commit. For a VPN implementation, this is the correct posture, not
technical debt:

- The code carrying the user's traffic is a known, reviewable revision.
- Builds are reproducible — critical when the artifact is a signed system extension.
- Upgrades are deliberate, reviewed events rather than a side effect of resolving dependencies.

**Do not replace the commit pin with a version range.** Update by reviewing the diff, testing
the tunnel end-to-end, and moving the pin.

### The architecture is correct

```
Qwave.app ──► NETunnelProviderManager ──► PacketTunnel.systemextension ──► libwg-go.a
 (UI)              (control plane)              (data plane)              (protocol)
```

Traffic never passes through the browser process. The extension is separately signed, separately
sandboxed, and separately entitled. A crash in the browser does not drop the tunnel, and a
compromise of the browser does not directly yield the tunnel's key material.

## Apple Silicon notes

- **`libwg-go.a` must be arm64.** A universal or x86_64-only static library will either bloat the
  bundle or fail to link. Verify with `lipo -info` after any dependency update — this is the
  most likely breakage from moving the pin.
- **Go runtime inside a system extension.** The Go scheduler runs its own threads inside the
  extension process. This is well-trodden — Mullvad, Tailscale, and WireGuard's own app all ship
  it — but it means the extension's memory and thread profile is not typical for a macOS
  extension, and it is worth measuring rather than assuming.
- **ChaCha20-Poly1305 over AES-GCM.** WireGuard's choice favours platforms without AES
  acceleration. Apple Silicon has excellent AES hardware, so this is not the optimal cipher on
  this hardware — but it is not negotiable in WireGuard, and throughput is not the binding
  constraint on a laptop link anyway.

## Adoption sketch

Already integrated. The operational rules worth writing down:

```swift
// Sources/PacketTunnel/PacketTunnelProvider.swift — fail closed
override func startTunnel(options: [String: NSObject]?) async throws {
    do {
        try await adapter.start(tunnelConfiguration: config)
    } catch {
        // Never fall back to an unprotected route. A VPN that fails open
        // is worse than no VPN, because the user believes they are protected.
        throw PacketTunnelError.startFailed(error)
    }
}
```

**Updating the pin — checklist:**

1. Review the upstream diff, with attention to handshake and timer logic.
2. Rebuild `libwg-go.a`; confirm `lipo -info` reports arm64.
3. Test tunnel establishment, teardown, sleep/wake, and network transition (Wi-Fi → cellular
   tether → Wi-Fi).
4. Verify DNS goes through the tunnel — leak testing is the point of the exercise.
5. Update the pin in `AGENTS.md` and the package manifest in the same commit.

## Risks

- **System extension approval is a difficult user experience.** `SystemExtensionActivator.swift`
  handles activation, but macOS requires explicit user approval in System Settings and the flow
  is easy to get lost in. This is a product risk more than a technical one.
- **Signing and notarisation.** Network extensions need specific entitlements and a Developer ID.
  Qwave ships unsigned builds today — see `docs/SIGNING.md`. The tunnel cannot fully work in an
  unsigned build, which limits what end users can currently exercise.
- **Pin drift.** A pinned dependency that is never reviewed becomes an unpatched dependency.
  Schedule a periodic review even when nothing appears to require one.
- **Go static library opacity.** `libwg-go.a` is a build artifact. Its provenance and build
  reproducibility matter for a sovereign browser; document how it is produced.

## Verdict

🟢 **Adopt — already integrated, and correctly.**

Commit pinning, process isolation, and `NETunnelProviderManager` are all the right calls. The
work remaining is not about this dependency; it is **Stage B** — signing, notarisation, the
approval flow, and end-to-end leak testing (see `docs/VPN_STAGE_B.md`).

**The rule worth recording:** the WireGuard pin moves only with a reviewed diff and a passing
end-to-end tunnel test. Never as part of a routine dependency update.
