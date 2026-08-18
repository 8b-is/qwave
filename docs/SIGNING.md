# Signing & Activating the VPN System Extension

CI builds Qwave unsigned (`CODE_SIGNING_ALLOWED=NO`), which is enough to verify
the code compiles and to produce a runnable browser — everything works except
the VPN tunnel. Packet-tunnel system extensions require a real signature and
the Network Extension entitlement, which only you can do, on your Mac, with
your Apple Developer account.

## Prerequisites

- Apple Developer Program membership (the paid one; free accounts can't get NE
  entitlements for system extensions).
- Xcode 16+ on macOS 14+.
- `brew install xcodegen`.

## One-time Apple setup

1. In [developer.apple.com](https://developer.apple.com/account) → Identifiers,
   create two App IDs:
   - `is.8b.qwave` (or your own reverse-DNS id — see "Renaming" below)
   - `is.8b.qwave.tunnel`
2. Enable **Network Extensions** capability on both, and **App Groups** with a
   group like `group.is.8b.qwave` on both.

## Building signed

1. Generate the project:

   ```sh
   cd qwave
   xcodegen generate
   open Qwave.xcodeproj
   ```

2. In both targets' Signing & Capabilities, confirm **Team** is
   `7CFQYBX575` and signing is **Automatic** (`project.yml` defaults).
   CI still builds unsigned (`CODE_SIGNING_ALLOWED=NO`); the release
   workflow forces Manual + Developer ID.

3. The entitlements files are generated from `project.yml` and already contain:
   - `com.apple.developer.networking.networkextension` → `packet-tunnel-provider-systemextension`
   - app group `$(TeamIdentifierPrefix)group.is.8b.qwave`
   - keychain access group `$(TeamIdentifierPrefix)is.8b.qwave.shared`

   `$(TeamIdentifierPrefix)` resolves to your team id at signing time; nothing
   to edit.

4. Build & run the `Qwave` scheme.

## Activating the extension

System extensions only activate from `/Applications`:

1. Build, then copy `Qwave.app` to `/Applications` and launch it from there.
2. Settings → VPN → **Install VPN System Extension…**
3. macOS will prompt: System Settings → Privacy & Security → allow the
   extension from "Qwave".
4. macOS asks to allow the VPN configuration when you first connect.

During development you can loosen Gatekeeper's grip on extension versioning:

```sh
systemextensionsctl developer on      # allows running from Xcode's build dir
systemextensionsctl list              # inspect installed extensions
```

## Connecting

1. Settings → VPN → paste your Mullvad account number → **Log In** (this
   registers a WireGuard device key, stored only in your keychain).
2. Pick a country / owned-only / DAITA filters as desired.
3. **Connect**. The menu-bar shield fills in when the tunnel is up.

## Troubleshooting

- `sysextd` logs: `log stream --predicate 'subsystem == "com.apple.sx"'`
- Qwave logs: `log stream --predicate 'subsystem == "is.8b.qwave"'`
- "VPN configuration error (…)" from the app almost always means the
  extension isn't activated or the entitlement is missing from the profile.
- If the tunnel starts but traffic doesn't flow, check that the WireGuard
  key registered with Mullvad matches the keychain key: log out and back in
  to rotate both together.

## CI release pipeline (signing, notarisation, Sparkle)

`.github/workflows/release.yml` builds every `v*` tag. Which path it takes
depends on which repository secrets exist:

| Secret | Purpose |
|---|---|
| `MACOS_CERTIFICATE_P12` | base64 of a `.p12` containing the **Developer ID Application** certificate + private key (`base64 -i cert.p12 \| pbcopy`) |
| `MACOS_CERTIFICATE_PASSWORD` | password of that `.p12` |
| `APPLE_TEAM_ID` | 10-char team id (e.g. `7CFQYBX575`) |
| `NOTARY_KEY_B64` | base64 App Store Connect API key `.p8` for `notarytool` |
| `NOTARY_KEY_ID` | the ASC API key's Key ID |
| `NOTARY_ISSUER_ID` | the ASC Issuer ID |
| `SPARKLE_ED_PRIVATE_KEY` | single-line base64 Ed25519 seed for signing Sparkle updates |

- **All signing secrets present** → Developer ID signed build (hardened
  runtime, timestamped), notarised via `notarytool`, stapled, verified with
  `spctl -a -vv`, shipped as a signed+stapled DMG.
  *Verified locally 2026-08-13*: the signed build's chain
  (`Developer ID Application` → `Developer ID Certification Authority` →
  `Apple Root CA`), hardened-runtime flag, and `codesign --verify --deep
  --strict` all pass; `spctl -a -vv` answers `rejected (Unnotarized
  Developer ID)` until notarisation runs, which is exactly the step the CI
  pipeline performs before its own `spctl` assertion.
- **Signing secrets absent** → unsigned build, shipped as
  `Qwave-vX.Y.Z-unsigned.zip` (the pre-v0.3.0 behaviour). Local dev keeps
  working unsigned: `CODE_SIGNING_ALLOWED=NO` still builds.
- **`SPARKLE_ED_PRIVATE_KEY` present** → `generate_appcast` (from the pinned
  Sparkle 2.9.5 distribution, checksum-verified) signs the DMG with EdDSA and
  publishes `appcast.xml` as a release asset. The app's `SUFeedURL` points at
  `releases/latest/download/appcast.xml`, so the appcast must ship with every
  release — the workflow re-downloads the previous appcast first to keep the
  update history.

### Sparkle update keys

The EdDSA **public** key is committed in `project.yml` (`SUPublicEDKey`). The
**private** seed lives only in `~/.qwave-secrets/sparkle_ed25519_seed.b64` on
the maintainer's machine and in the `SPARKLE_ED_PRIVATE_KEY` repo secret.
Rotating it means: generate a new pair (`Sparkle`'s `generate_keys`, or any
Ed25519 tool emitting a base64 32-byte seed), update `SUPublicEDKey`, update
the secret, and ship one release signed with **both** keys' signatures per
Sparkle's key-rotation guidance.

### Network Extension entitlements under Developer ID

The app and PacketTunnel entitlements declare
`com.apple.developer.networking.networkextension`
(`packet-tunnel-provider-systemextension`). Manual Developer ID signing with
those entitlements fails outright — verified 2026-08-13 with a local
Developer ID identity:

```
error: "Qwave" requires a provisioning profile with the Network Extensions
feature. Select a provisioning profile in the Signing & Capabilities editor.
```

Fixing that requires Apple's **Developer ID Network Extension approval** and
Developer ID provisioning profiles for `is.8b.qwave` / `is.8b.qwave.tunnel`
— an Apple-side process, not a repo change. Until then, the CI signed path
uses empty entitlements from `Resources/CI/Distribution-NoVPN.entitlements`:
the signed app browses and auto-updates, but VPN activation is not available in
CI-signed builds. Local Xcode signing with your team (see above) remains the
working path for VPN testing.

When Apple approval is granted, add these repository secrets:

| Secret | Contents |
|---|---|
| `MACOS_APP_PROVISIONING_PROFILE_B64` | Base64 Developer ID profile for `is.8b.qwave` |
| `MACOS_TUNNEL_PROVISIONING_PROFILE_B64` | Base64 Developer ID profile for `is.8b.qwave.tunnel` |

The release workflow installs both profiles, passes their names to the two
XcodeGen targets, uses the real entitlements from `project.yml`, and verifies
the Network Extension entitlement on both the app and embedded system
extension before notarization. If either profile is missing, it deliberately
falls back to the no-VPN signed artifact instead of producing a misleading
partially entitled release.

## Renaming

`is.8b.qwave` is a placeholder identity. To rebrand: change `bundleIdPrefix`,
the two `PRODUCT_BUNDLE_IDENTIFIER`s, the app group, keychain group, and
`NEMachServiceName` in `project.yml`, plus `SystemExtensionActivator.extensionIdentifier`
and `TunnelManager.providerBundleIdentifier` defaults in the sources. Grep for
`is.8b.qwave` — every occurrence is intentional and greppable.
