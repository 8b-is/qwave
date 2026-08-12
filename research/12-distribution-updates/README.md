# 12 · Distribution & Updates

| Package | Version | Verdict | Qwave relevance |
|---------|---------|---------|-----------------|
| [Sparkle](sparkle.md) | 2.9.5 | 🟢 Adopt | The missing piece of the release story |

---

## The problem

Qwave v0.1.0 ships as an **unsigned zip** from GitHub Releases. That means every user:

1. Downloads a zip manually.
2. Bypasses Gatekeeper to run it.
3. Has no way to learn a new version exists.
4. Repeats all of this for every update.

For a **security-focused browser** this is the weakest part of the product, and the reason is
specific rather than aesthetic: **a browser that cannot ship security updates quickly is not a
secure browser.** WebKit vulnerabilities are patched in macOS updates for Safari, but Qwave's own
code — `Shields`, `VPNKit`, `Persistence` — updates only when the user happens to check GitHub.

Teaching users to bypass Gatekeeper is its own harm. It normalises exactly the behaviour that
makes people vulnerable elsewhere.

## The dependency chain

Auto-update cannot be solved in isolation. It requires signing first:

```
Developer ID certificate
        ↓
Code signing (app + PacketTunnel.systemextension)
        ↓
Notarisation + stapling
        ↓
Sparkle auto-update with EdDSA-signed appcast
        ↓
The VPN system extension can actually be approved by users
```

That last step is not a bonus. **Network extensions require proper signing and entitlements** —
so the VPN feature described in the README cannot fully work for end users until this chain is
complete. `docs/SIGNING.md` and `docs/VPN_STAGE_B.md` already acknowledge this.

Signing therefore unblocks two things at once: trustworthy updates, and the VPN.

## Why Sparkle specifically

For a non-App-Store Mac app it is effectively the standard: Sparkle 2 supports sandboxing,
custom UI, external bundle updates, and a modern installer architecture. It has been the answer
for two decades of Mac software.

The alternative — App Store distribution — is a poor fit here. The sandbox restrictions,
system-extension approval flow, and Safari SPI usage in `FeatureFlags` all sit awkwardly with App
Store review, and the sovereignty positioning argues for direct distribution regardless.

## Sequence

1. Obtain a Developer ID certificate.
2. Sign the app and the system extension; configure `project.yml` accordingly.
3. Notarise and staple in `release.yml`.
4. Add Sparkle with an EdDSA-signed appcast.
5. Verify the system extension approval flow works end to end on a clean machine.

Steps 1–3 are prerequisites for everything else in this category and for Stage B of the VPN.
