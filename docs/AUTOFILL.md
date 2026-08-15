# AutoFill Credential Provider — design spike

> Status: **spike / groundwork.** This document is the design; the code that
> ships alongside it is a build-safe scaffold, not working AutoFill. The
> scaffold (`Sources/CredentialProvider/`) is deliberately **not yet wired
> into `project.yml`** — see [Wiring the target](#wiring-the-target-the-next-step)
> for why, and for the exact next step. No credentials are stored, filled, or
> created yet.

## Why a browser needs this at all

Qwave is built on `WKWebView`. WebKit gives an app **nothing** for password
AutoFill: unlike Safari, an embedding app cannot ask WebKit to fill a login
form, offer a saved password in a QuickType-style bar, or drive a passkey
ceremony from page JavaScript. Those affordances belong to the system, and the
system only offers them to two kinds of participant:

- **AutoFill credential providers** — an app-extension of type
  *AutoFill Credential Provider* that the user enables in
  System Settings → Passwords → Password Options. macOS then routes AutoFill
  requests originating anywhere (including inside our `WKWebView`) to the
  extension.
- **Relying-party clients** — code that runs a WebAuthn ceremony itself via
  `ASAuthorizationController` (Sign in with Apple, security keys, passkeys).

A Developer-ID browser that wants first-class login/passkey UX has to become
the first kind (register an `ASCredentialProviderExtension`) and, for the
in-page "sign in" affordances a site invokes, speak the second (drive
`ASAuthorizationController`). This spike scopes the extension; the
`ASAuthorizationController` client path is noted where it touches the design.

## Architecture

```
Qwave.app  (WKWebView host)
├─ is.8b.qwave                     app target — hosts + embeds the extension
└─ PlugIns/CredentialProvider.appex
   └─ is.8b.qwave.autofill         AutoFill Credential Provider extension
      └─ CredentialProviderViewController : ASCredentialProviderViewController
```

The extension is a separate bundle with its **own** bundle id
(`is.8b.qwave.autofill`), its own Info.plist, and its own entitlements. The
system launches it out-of-process on demand; it does not share an address
space with the browser. The principal class subclasses
`ASCredentialProviderViewController` (on macOS an `NSViewController`) and
overrides the request lifecycle.

### Request lifecycle (what the scaffold stubs)

| Override | Called when | Spike behaviour |
|---|---|---|
| `prepareCredentialList(for:)` | User opens the extension from the AutoFill list for a set of `ASCredentialServiceIdentifier`s | Presents an empty list (no store yet) |
| `provideCredentialWithoutUserInteraction(for:)` | User taps a QuickType suggestion whose identity was pre-registered | Cancels with `userInteractionRequired` (nothing unlocked) |
| `prepareInterfaceToProvideCredential(for:)` | System needs UI to fulfil the request (e.g. unlock a vault) | Cancels with `credentialIdentityNotFound` |
| `prepareInterface(forPasskeyRegistration:)` | User picks Qwave to create a new passkey (macOS 14+) | Cancels — passkey creation not in the spike |
| `prepareInterfaceForExtensionConfiguration()` | User enables/opens Qwave in Password Options | Completes the configuration request (nothing to configure) |

All request completions go through `extensionContext`
(`ASCredentialProviderExtensionContext`):
`completeRequest(withSelectedCredential:completionHandler:)`,
`completeAssertionRequest(using:completionHandler:)`, or `cancelRequest(withError:)`.
The scaffold only ever cancels or completes-empty, so AutoFill dismisses
cleanly and never hangs.

## Password AutoFill

The end-to-end shape once implemented:

1. **Registration.** When Qwave saves or imports a login, it writes an
   `ASPasswordCredentialIdentity` (service = the site, user = the username) into
   the shared `ASCredentialIdentityStore` via
   `saveCredentialIdentities(_:completion:)`. This is metadata only — the
   identity tells the system *what* Qwave can fill, not the secret itself.
2. **QuickType.** The user focuses a login field in a page. macOS matches the
   field's domain against stored identities and shows Qwave's entries in the
   AutoFill bar.
3. **Fill without UI.** On tap, the system calls
   `provideCredentialWithoutUserInteraction(for:)`. If Qwave's vault is
   unlocked, it returns the matching `ASPasswordCredential` (username +
   password) and the system fills the form. If a vault unlock is needed, Qwave
   cancels with `userInteractionRequired`, which prompts the system to call
   `prepareInterfaceToProvideCredential(for:)` for the interactive path.

## Passkeys

Passkeys move through the **same extension** on macOS 14+, using the
request-based API (`any ASCredentialRequest`):

- **Assertion (sign-in).** A page calls `navigator.credentials.get()`; WebKit
  turns it into a passkey assertion request. The extension resolves it in
  `prepareCredentialList(for:requestParameters:)` /
  `provideCredentialWithoutUserInteraction(for:)` and completes with
  `completeAssertionRequest(using:)`.
- **Registration (create).** A page calls `navigator.credentials.create()`;
  the user may pick Qwave to hold the new passkey, which routes to
  `prepareInterface(forPasskeyRegistration:)`. Conditional (silent)
  registration additionally requires the `SupportsConditionalPasskeyRegistration`
  capability in the extension's Info.plist.

Separately, for in-page "Sign in with a passkey" affordances that Qwave wants
to drive itself (rather than delegate to whatever provider the user enabled),
the **app** runs the ceremony with `ASAuthorizationController` +
`ASAuthorizationPlatformPublicKeyCredentialProvider`. That path is app-side, not
extension-side, and is out of scope for this scaffold but shares the same
credential model.

## ASCredentialIdentityStore

`ASCredentialIdentityStore.shared` is the system index of "identities Qwave can
offer." Key operations:

- `getState(_:)` — is the extension enabled? Only save when enabled.
- `saveCredentialIdentities(_:completion:)` / `removeCredentialIdentities(_:completion:)`
  — keep the index in sync as the user's saved logins change.
- `replaceCredentialIdentities(with:completion:)` — full resync (e.g. after an
  import).

The store holds **only identities (metadata)** — the site, the username, a
record identifier. The secret material never lives here; it is fetched by the
extension at fill time from Qwave's own store (below).

## iCloud Keychain interop

iCloud Keychain is itself a credential provider, always present. Qwave's
extension is **additive**: when both are enabled the AutoFill bar shows entries
from each. Practical consequences the design must respect:

- **No takeover.** Enabling Qwave does not disable or migrate iCloud Keychain.
  The user keeps both; Qwave never reads Apple's store.
- **Domain association.** For AutoFill to match the right site (and for passkey
  scoping), credentials are keyed by their web domain exactly as Apple's own
  associated-domains model expects.
- **De-dup is the system's job.** If the same login exists in both providers,
  macOS shows both; Qwave does not attempt to reconcile Apple's entries.

## Entitlements required

The extension target carries:

- `com.apple.developer.authentication-services.autofill-credential-provider`
  → `true` — the AutoFill Credential Provider capability. Enforced only when
  signed with a real team id (same posture as the VPN entitlements in
  [SIGNING.md](SIGNING.md); CI builds `CODE_SIGNING_ALLOWED=NO`).

To share the encrypted credential vault between the app (which saves/imports)
and the extension (which fills), both need a common access path:

- `com.apple.security.application-groups` → `group.is.8b.qwave` (already
  granted to the app and PacketTunnel).
- `keychain-access-groups` → `$(TeamIdentifierPrefix)is.8b.qwave.shared`
  (already granted to the app).

Passkey support additionally requires the `ProvidesPasskeys` capability to be
advertised; per Apple both the containing app and the extension must declare it
in their `ASCredentialProviderExtensionCapabilities` dictionaries. The exact
app-side Info.plist placement is a wiring detail to confirm during target
integration.

The extension's `NSExtension` Info.plist block:

```
NSExtension
├─ NSExtensionPointIdentifier => com.apple.authentication-services-credential-provider-ui
├─ NSExtensionPrincipalClass  => $(PRODUCT_MODULE_NAME).CredentialProviderViewController
└─ NSExtensionAttributes
   └─ ASCredentialProviderExtensionCapabilities
      ├─ ProvidesPasswords => true
      └─ ProvidesPasskeys  => true
```

## macOS availability

- `ASCredentialProviderViewController` and password AutoFill providers: macOS
  11.0+.
- The request-based passkey API (`any ASCredentialRequest`,
  `prepareInterface(forPasskeyRegistration:)`, assertion completion): macOS
  14.0+.

Qwave's deployment target is macOS 14.0, so the scaffold gates its principal
class with `@available(macOS 14.0, *)` and uses the modern request-based
overrides throughout. No back-deployment shims are needed.

## Separation from DeviceKeyManager

**Critical, and load-bearing for the security story.** Qwave's credential vault
is a *different thing* from the post-quantum device-identity crypto and MUST
stay that way:

- `DeviceKeyManager` / ML-KEM / `MemoryCipher` / VPNKit exist to authenticate
  the **device** to the Mullvad relay and to key the VPN tunnel
  (`Packages/QwaveKit/Sources/VPNKit/DeviceKeyManager.swift`). Those keys are
  the device's network identity.
- The AutoFill vault stores the **user's third-party website logins and
  passkeys**. It is user data, per-site, and has nothing to do with device
  identity or the tunnel.

Conflating them would be a real hazard: it would put website passwords behind
the same key that authenticates the VPN device, couple two unrelated threat
models, and risk one subsystem's rotation/erase logic destroying the other's
data. The design therefore keeps them fully isolated:

- The extension links **neither** VPNKit **nor** the ML-KEM stack. It does not
  import `DeviceKeyManager`, `MemoryCipher`, or any `Packages/` crypto module.
  The scaffold imports only `AuthenticationServices` and `os`.
- Credential secrets live in their own keychain items / vault, distinct from
  the VPN key material (which is a `kSecClassGenericPassword` item under
  `DeviceKeyManager.privateKeyStorageKey`). Even though both can ride the same
  `keychain-access-groups` sharing group, they are separate accounts and are
  never interchanged.
- No AutoFill data path touches crypto owned by the VPN/device stack. This
  boundary is a hard constraint on any follow-up.

## What the spike ships

- This design document.
- `Sources/CredentialProvider/CredentialProviderViewController.swift` — a stub
  `ASCredentialProviderViewController` that compiles against the macOS 14 SDK
  and returns an empty / cancelled result on every path. No storage, no fill,
  no passkey creation.

## What the spike does **not** ship

- No `project.yml` target (see below) — so nothing new is embedded, signed, or
  built into the app yet.
- No credential storage, no `ASCredentialIdentityStore` writes, no fill logic,
  no passkey ceremonies, no UI.

## Wiring the target (the next step)

Adding a signed app-extension target is the risky part: it introduces a new
bundle id nested under the app, an embed step, entitlement propagation to the
app, and a passkey-capability plist contract — any of which can break an
otherwise-green `CODE_SIGNING_ALLOWED=NO` build and would collide with sibling
work already editing `project.yml`. So this spike intentionally stops short of
it. When the target is wired, add roughly this block to `project.yml`
`targets:` (and an `embed: true` dependency from the `Qwave` target, mirroring
how `PacketTunnel` is embedded):

```yaml
  CredentialProvider:
    type: app-extension
    platform: macOS
    sources:
      - path: Sources/CredentialProvider
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: is.8b.qwave.autofill
        PRODUCT_NAME: CredentialProvider
    info:
      path: Resources/CredentialProvider/Info.plist
      properties:
        CFBundleDisplayName: Qwave Passwords
        NSExtension:
          NSExtensionPointIdentifier: com.apple.authentication-services-credential-provider-ui
          NSExtensionPrincipalClass: $(PRODUCT_MODULE_NAME).CredentialProviderViewController
          NSExtensionAttributes:
            ASCredentialProviderExtensionCapabilities:
              ProvidesPasswords: true
              ProvidesPasskeys: true
    entitlements:
      path: Resources/CredentialProvider/CredentialProvider.entitlements
      properties:
        com.apple.developer.authentication-services.autofill-credential-provider: true
        com.apple.security.application-groups:
          - $(TeamIdentifierPrefix)group.is.8b.qwave
        keychain-access-groups:
          - $(TeamIdentifierPrefix)is.8b.qwave.shared
```

Then, in one surgical change: add `- target: CredentialProvider` with
`embed: true` to the `Qwave` target's `dependencies`, regenerate, and verify
the `CODE_SIGNING_ALLOWED=NO` build stays green before layering in any storage
or fill logic.

## Follow-ups

- Design the credential vault (schema, encryption, per-site records) as a store
  separate from VPN key material.
- Implement `ASCredentialIdentityStore` sync on save/import/delete.
- Implement password fill (`provideCredentialWithoutUserInteraction` +
  interactive unlock).
- Implement passkey assertion + registration.
- Confirm the app-side `ProvidesPasskeys` plist placement against a signed
  build on a real team id.
- Decide the in-page `ASAuthorizationController` client path for
  Qwave-driven passkey ceremonies.
