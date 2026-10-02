# Signing Qwave

CI builds Qwave unsigned (`CODE_SIGNING_ALLOWED=NO`), which is enough to
verify the code compiles and to produce a runnable browser. Distribution —
Developer ID signing, notarisation, and the Sparkle update feed — is layered
on top, driven entirely by which credentials exist.

## Local development signing

1. Generate the project:

   ```sh
   cd qwave
   xcodegen generate --spec project.yml
   open Qwave.xcodeproj
   ```

2. In the `Qwave` target's Signing & Capabilities, confirm **Team** is
   `CKQ9Q43ANM` and signing is **Automatic** (`project.yml` defaults).
   The `CredentialProvider` extension (AutoFill) needs the same team so the
   app-group and keychain-group entitlements resolve.

3. The entitlements files are generated from `project.yml`:
   - app group `$(TeamIdentifierPrefix)group.is.8b.qwave`
   - keychain access group `$(TeamIdentifierPrefix)is.8b.qwave.shared`
   - `com.apple.developer.authentication-services.autofill-credential-provider`
     on the CredentialProvider extension

   `$(TeamIdentifierPrefix)` resolves to your team id at signing time;
   nothing to edit. The `networkextension` entry in `Qwave.entitlements` is a
   leftover of the removed VPN layer and is deliberately not enforced — see
   the Developer ID section below.

4. Build & run the `Qwave` scheme.

## CI release pipeline (signing, notarisation, Sparkle)

`.github/workflows/release.yml` builds every `v*` tag. Which path it takes
depends on which repository secrets exist:

| Secret | Purpose |
|---|---|
| `MACOS_CERTIFICATE_P12` | base64 of a `.p12` containing the **Developer ID Application** certificate + private key (`base64 -i cert.p12 \| pbcopy`) |
| `MACOS_CERTIFICATE_PASSWORD` | password of that `.p12` |
| `APPLE_TEAM_ID` | 10-char team id (e.g. `CKQ9Q43ANM`) |
| `NOTARY_KEY_B64` | base64 App Store Connect API key `.p8` for `notarytool` |
| `NOTARY_KEY_ID` | the ASC API key's Key ID |
| `NOTARY_ISSUER_ID` | the ASC Issuer ID |
| `SPARKLE_ED_PRIVATE_KEY` | single-line base64 Ed25519 seed for signing Sparkle updates |

- **All signing secrets present** → Developer ID signed build (hardened
  runtime, timestamped), notarised via `notarytool`, stapled, verified with
  `spctl -a -vv`, shipped as a signed+stapled DMG.
- **Signing secrets absent** → unsigned build, shipped as
  `Qwave-vX.Y.Z-unsigned.zip`. Local dev keeps working unsigned:
  `CODE_SIGNING_ALLOWED=NO` still builds.
- **`SPARKLE_ED_PRIVATE_KEY` present** (and the build signed + notarised) →
  `generate_appcast` (from the pinned Sparkle 2.9.5 distribution,
  checksum-verified) signs the DMG with EdDSA and publishes `appcast.xml` as
  a release asset. The app's `SUFeedURL` points at
  `releases/latest/download/appcast.xml`, so the appcast must ship with every
  release — the workflow re-downloads the previous appcast first to keep the
  update history.

The workflow also hard-errors before notarisation if any embedded Sparkle
helper lacks a Developer ID signature + hardened runtime: the notary service
rejects them, and failing early beats failing at `notarytool`.

### Sparkle update keys

The EdDSA **public** key is committed in `project.yml` (`SUPublicEDKey`). The
**private** seed lives only in `~/.qwave-secrets/sparkle_ed25519_seed.b64` on
the maintainer's machine and in the `SPARKLE_ED_PRIVATE_KEY` repo secret.
Rotating it means: generate a new pair (`Sparkle`'s `generate_keys`, or any
Ed25519 tool emitting a base64 32-byte seed), update `SUPublicEDKey`, update
the secret, and ship one release signed with **both** keys' signatures per
Sparkle's key-rotation guidance.

### The leftover Network Extension entitlement

`Qwave.entitlements` still declares
`com.apple.developer.networking.networkextension` from the removed VPN layer.
Manual Developer ID signing with that entitlement fails outright (Apple
reserves NE for approved provisioning profiles), so the CI signed path
overrides the generated entitlements with
`Resources/CI/Distribution-NoVPN.entitlements`
(`CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`): the signed app browses and
auto-updates, and the entitlements it actually carries are honest. Dropping
the NE entry from `project.yml` is the cleanup; the app-group and keychain
groups must stay.

## Renaming

`is.8b.qwave` is the 8b.IS identity. To rebrand: change `bundleIdPrefix`, the
`PRODUCT_BUNDLE_IDENTIFIER`s (`is.8b.qwave`, `is.8b.qwave.mcp`,
`is.8b.qwave.autofill`, `is.8b.qwave.ios`), the app group, and the keychain
group in `project.yml`, plus the QwaveURL scheme handler and any
`is.8b.qwave` defaults in the sources. Grep for `is.8b.qwave` — every
occurrence is intentional and greppable.
