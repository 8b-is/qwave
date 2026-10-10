# Native website passkeys

Qwave uses WKWebView. The supported website path is WebKit's native WebAuthn
implementation and Apple's credential-provider UI. Private keys remain with
Apple Passwords / iCloud Keychain or the user's selected credential provider.
Qwave must not spoof capability results, replace navigator.credentials with a
partial polyfill, or collect/export credential-provider private keys.

## Current checkpoint

2.0.5 (20005) is available in internal TestFlight, but full website passkeys
are **not verified**. Its iOS signed archive has no managed browser entitlement.
The App Store Connect bundle-capabilities response for `is.8b.q-wave` also has
no browser capability (checked 2026-10-10). The Mac-only WebAuthnBridge exposes
custom helper functions, not the standard navigator.credentials API. That
helper is not the native website path and must not be advertised as full support.
Qwave's own credential-provider extension is separate from using existing
passkeys; implementing a new passkey vault is outside this integration.

## iPhone approval and build

1. Request Apple's default-browser managed entitlement for bundle identifier
   `is.8b.q-wave`, team `CKQ9Q43ANM`. Sign in to the authorized Developer account.
   Do not request the unrelated app-installation entitlement.
2. Validate browser eligibility: HTTP/HTTPS scheme registration, omnibox/search,
   direct destination rendering, no UIWebView, and only necessary permissions.
   Incoming HTTP/HTTPS links use onOpenURL; validate cold and warm launches on
   device. The external entry point rejects script/internal/file schemes and
   embedded username/password URLs.
3. After Apple approval, enable the capability on the identifier and regenerate
   provisioning. Generate `xcodegen generate --spec project-browser-ios.yml`.
   This opt-in configuration adds `com.apple.developer.web-browser`; the ordinary
   `project-app-store.yml` remains usable before approval. Never hand-edit the
   generated Xcode project or treat a local entitlement as Apple's approval.
4. Verify the entitlement in BOTH the distribution profile and exported signed
   app. Build and upload a new version only after this check and device testing.

## macOS

Apple documents a separately managed
`com.apple.developer.web-browser.public-key-credential` entitlement, requested
by the Account Holder of an organization Developer account. Check account
eligibility before requesting it. The existing default-browser URL schemes
alone do not prove this permission. Integrate the documented authorization
state/request UI where required; denial must remain respected. Do not add an
unapproved entitlement to the normal release build.

## Acceptance on real devices

Use a disposable test account for registration and explicit user interaction
for existing-account authentication. Verify native create/get, GitHub sign-in,
conditional/AutoFill selection, cancellation, denied access, private tabs,
origin/RP isolation, external security keys and cross-device authentication on
supported OS versions. Record which OS/provider combinations actually pass.
Never claim every passkey transport works from a successful build or feature
probe. Do not create, replace, delete or enroll real account credentials as an
automated test.

## Prepared Apple request summary

App: Qwave Browser. Bundle ID: is.8b.q-wave. Team: CKQ9Q43ANM.
Product/support: https://qwave.8b.is/ and https://qwave.8b.is/support/.
Contact: c@8b.is.

Qwave is a general-purpose iPhone web browser using the system WKWebView. It
provides an address/search field and tabbed navigation. We request the default
browser entitlement so users can select Qwave as their browser and use native
browser capabilities, including website passkey authentication. Qwave intends
to delegate WebAuthn to WebKit and the user's system credential provider.
HTTP/HTTPS registration and incoming-link validation are prepared; device QA
and the approved distribution profile are required before shipping this capability.

## Apple references

- https://developer.apple.com/documentation/authenticationservices/passkey-use-in-web-browsers
- https://developer.apple.com/documentation/xcode/preparing-your-app-to-be-the-default-browser
- https://developer.apple.com/contact/request/default-browser-entitlement/
- https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential
- https://developer.apple.com/contact/request/macos-browsers-passkeys/
