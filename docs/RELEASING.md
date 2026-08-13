# Releasing Qwave

Two paths, same shape: pushing a `v*` tag runs
`.github/workflows/release.yml`; `scripts/release.sh vX.Y.Z` mirrors it
locally. Both degrade gracefully — every missing credential removes a step,
never breaks the build.

## Version bump checklist (before tagging)

1. `project.yml`: `CFBundleShortVersionString` on **both** targets = `X.Y.Z`.
2. `project.yml`: `CFBundleVersion` on **both** targets =
   `X*10000 + Y*100 + Z` (0.3.0 → 300). Sparkle compares this number; the
   workflow fails the tag if it doesn't match.
3. `CHANGELOG.md` entry.

## Dry run, then the real tag

```sh
git tag v0.3.0-rc.1 && git push origin v0.3.0-rc.1   # prerelease dry run
# verify the workflow: artifacts correct, release marked prerelease,
# NO appcast attached (rc builds never enter the update feed)
git tag v0.3.0 && git push origin v0.3.0             # the real thing
```

## Repository secrets (Settings → Secrets → Actions)

| Secret | Enables | How to produce |
|---|---|---|
| `MACOS_CERTIFICATE_P12` | Developer ID signing | Export the "Developer ID Application" identity from Keychain Access as `.p12`, then `base64 -i cert.p12 \| pbcopy` |
| `MACOS_CERTIFICATE_PASSWORD` | — | the `.p12` password |
| `APPLE_TEAM_ID` | signing + notarisation | 10-char team id from developer.apple.com |
| `NOTARY_APPLE_ID` | notarisation | the Apple ID |
| `NOTARY_PASSWORD` | notarisation | app-specific password (appleid.apple.com → Sign-In and Security) |
| `SPARKLE_ED_PRIVATE_KEY` | appcast signing | single-line base64 Ed25519 seed (already set; rotation in docs/SIGNING.md) |

Behavior by configuration:

- **No secrets** → unsigned zip + DMG, no appcast. Never red.
- **Sparkle key only** (current state) → same as above; the appcast step is
  additionally gated on the signed+notarised path, because unsigned builds
  must never enter the EdDSA-trusted update channel (and `generate_appcast`
  rejects them anyway).
- **All secrets** → signed (hardened runtime, no `get-task-allow`),
  notarised, stapled DMG; `spctl -a -vv` asserted in CI; `appcast.xml`
  published. The CI also verifies the Sparkle private key pairs with the
  committed `SUPublicEDKey` before signing the feed.

## Local mirror

```sh
QWAVE_SIGN_IDENTITY="Developer ID Application" \
QWAVE_TEAM_ID=7CFQYBX575 \
QWAVE_NOTARY_PROFILE=qwave-notary \
QWAVE_SPARKLE_KEY=~/.qwave-secrets/sparkle_ed25519_seed.b64 \
scripts/release.sh v0.3.0
```

Store the notary profile once with
`xcrun notarytool store-credentials qwave-notary --apple-id … --team-id …`.
Artifacts land in `build/release/`.

## Known limits

- CI-signed builds carry no Network Extension entitlements until Apple's
  Developer ID NE approval + provisioning profiles exist — the VPN
  activates only in local Xcode-signed builds. Details: `docs/SIGNING.md`.
- The appcast must ship with every stable release (the feed URL is
  `releases/latest/download/appcast.xml`); the workflow re-downloads the
  previous appcast first so history carries forward.
