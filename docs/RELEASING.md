# Releasing Qwave

Two paths, same shape: pushing a `v*` tag runs
`.github/workflows/release.yml`; `scripts/release.sh vX.Y.Z` mirrors it
locally. Both degrade gracefully — every missing credential removes a step,
never breaks the build.

## Versioning

`project.yml` is the **single source of truth**. Every target — `Qwave`,
`CredentialProvider`, `QwaveIOS` — declares the same two numbers:

- `CFBundleShortVersionString` = the semver, `X.Y.Z` (currently `2.0.0`).
- `CFBundleVersion` = `X*10000 + Y*100 + Z` (2.0.0 → `20000`). Sparkle
  compares this number, and the release workflow **fails the tag** if any
  target disagrees. Bump all targets together, always.

The `v2.0.0` major covers the Rust-core rewrite: the VPN layer removal, the
sovereign core (`core/`), the stable/nightly channel split, and the removal
of Go/Zig from the build.

## Version bump checklist (before tagging)

1. `project.yml`: `CFBundleShortVersionString` on **all three** targets =
   `X.Y.Z`.
2. `project.yml`: `CFBundleVersion` on **all three** targets =
   `X*10000 + Y*100 + Z`. Sparkle compares this number; the workflow fails
   the tag if it doesn't match.
3. `CHANGELOG.md` entry (move `[Unreleased]` → `[X.Y.Z]`).
4. If a nightly snapshot accompanies the release, rebuild it with
   `tools/install-nightly.sh` on a reference Mac and smoke it.

## Dry run, then the real tag

```sh
git tag v2.0.0-rc.1 && git push origin v2.0.0-rc.1   # prerelease dry run
# verify the workflow: artifacts correct, release marked prerelease,
# NO appcast attached (rc builds never enter the update feed)
git tag v2.0.0 && git push origin v2.0.0             # the real thing
```

The local mirror runs the same gates without CI:

```sh
scripts/release.sh v2.0.0          # unsigned zip + DMG, no appcast
scripts/release.sh v2.0.0-rc.1     # prerelease: same shapes, still no appcast
```

**v2.0.0 shipped this way on 2026-10-03**: signed, notarised, stapled
(`spctl -a -vv` accepted), appcast attached to the GitHub Release — the full
pipeline, run locally because the org's Actions runners are not enabled.

Notary credentials: `scripts/release.sh` prefers the **direct ASC API key**
(`QWAVE_NOTARY_KEY` / `QWAVE_NOTARY_KEY_ID` / `QWAVE_NOTARY_ISSUER_ID`, the
same flags `release.yml` uses). notarytool 1.x refuses to store API keys into
a profile that ever held apple-id credentials, so the
`QWAVE_NOTARY_PROFILE` path is the fallback, not the primary.

The signing team: the **Developer ID Application** identity on the
maintainer's Mac is team `7CFQYBX575` — pass that as `QWAVE_TEAM_ID`, not
the development team `CKQ9Q43ANM` from `project.yml` (which is for
automatic local signing). Mismatched teams fail with "No signing
certificate … matching team ID".

## Nightly releases

```sh
scripts/release-nightly.sh          # universal Release, unsigned, no appcast
git push origin main                # the tag moves to the build commit
git push origin "$(git rev-parse --short HEAD):refs/tags/nightly" -f
gh release delete nightly -y
gh release create nightly build/release-nightly/Qwave-nightly-*.zip \
  build/release-nightly/Qwave-nightly-*.dmg --prerelease --title "Qwave nightly" --target main
```

Nightly is a **rolling prerelease**, unsigned by design (the signed +
notarised lane is stable's), and never enters the Sparkle feed — the
appcast is stable-only. The `nightly` tag does not match `v*`, so the
release workflow ignores it.

## Repository secrets (Settings → Secrets → Actions)

| Secret | Enables | How to produce |
|---|---|---|
| `MACOS_CERTIFICATE_P12` | Developer ID signing | Export the "Developer ID Application" identity from Keychain Access as `.p12`, then `base64 -i cert.p12 \| pbcopy` |
| `MACOS_CERTIFICATE_PASSWORD` | — | the `.p12` password |
| `APPLE_TEAM_ID` | signing | 10-char team id from developer.apple.com |
| `NOTARY_KEY_B64` | notarisation | base64 of the App Store Connect API key `.p8` |
| `NOTARY_KEY_ID` | notarisation | the ASC API key's Key ID |
| `NOTARY_ISSUER_ID` | notarisation | ASC → Users & Access → Integrations → Issuer ID |
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
QWAVE_NOTARY_KEY=~/Documents/AuthKey_GS76KJ5978.p8 \
QWAVE_NOTARY_KEY_ID=GS76KJ5978 \
QWAVE_NOTARY_ISSUER_ID=5f48110e-66f5-40a2-ac5c-e0c225bee5ac \
QWAVE_SPARKLE_KEY=~/.qwave-secrets/sparkle_ed25519_seed.b64 \
scripts/release.sh v2.0.0
```

Artifacts land in `build/release/`.

## Known limits

- Signed builds carry the CI no-VPN entitlements
  (`Resources/CI/Distribution-NoVPN.entitlements`): the generated app
  entitlements still declare the Network Extension capability (a leftover of
  the removed VPN layer), and a Developer ID identity without Apple's NE
  approval would fail to sign them. Details: `docs/SIGNING.md`.
- The appcast must ship with every stable release (the feed URL is
  `releases/latest/download/appcast.xml`); the workflow re-downloads the
  previous appcast first so history carries forward.
