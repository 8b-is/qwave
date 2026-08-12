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

2. In both targets' Signing & Capabilities:
   - Set your **Team**.
   - Switch signing to **Automatic** (the checked-in project defaults to
     Manual so CI stays quiet).

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

## Renaming

`is.8b.qwave` is a placeholder identity. To rebrand: change `bundleIdPrefix`,
the two `PRODUCT_BUNDLE_IDENTIFIER`s, the app group, keychain group, and
`NEMachServiceName` in `project.yml`, plus `SystemExtensionActivator.extensionIdentifier`
and `TunnelManager.providerBundleIdentifier` defaults in the sources. Grep for
`is.8b.qwave` — every occurrence is intentional and greppable.
