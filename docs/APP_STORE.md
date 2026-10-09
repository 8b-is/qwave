# Apple store distribution

The store project is a separate distribution flavor, generated from
`project.yml` plus `project-app-store.yml`. Version numbers remain in
`project.yml`. The direct-download and nightly projects retain their existing
behavior.

## Build

Use Xcode 26.3 or newer with Swift 6.2, XcodeGen 2.46 or newer, and Rust with
the targets required by the destination. The repository's CI toolchain remains
Xcode 26.3; a successful newer local build does not replace that gate.

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
xcodegen generate --spec project-app-store.yml

xcodebuild -project QwaveAppStore.xcodeproj -scheme QwaveIOSAppStore \
  -destination 'generic/platform=iOS Simulator' -configuration Debug \
  -derivedDataPath build/store-ios CODE_SIGNING_ALLOWED=NO ARCHS=arm64 -jobs 2 build

xcodebuild -project QwaveAppStore.xcodeproj -scheme QwaveAppStore \
  -destination 'platform=macOS,arch=arm64' -configuration Debug \
  -derivedDataPath build/store-mac CODE_SIGNING_ALLOWED=NO ARCHS=arm64 -jobs 2 build

swift test --package-path Packages/QwaveKit --traits AppStore -j 2 \
  --filter FeatureFlagServiceTests

xcodebuild -project QwaveAppStore.xcodeproj -scheme QwaveTabBarTests \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO -jobs 2 test
```

The `AppStore` Swift package trait compiles the shared feature service without
private WebKit discovery or invocation. The Xcode build flag separately removes
the desktop inspector shortcut implementation and experimental settings pane.
Both are required. The store dependency graph omits Sparkle, and the updater
facade offers no update menu or background updater. Apple delivers updates.

The Mac app and credential extension declare App Sandbox. The app requests
outbound networking, user-selected files, Downloads, camera, microphone and
location capabilities used by browser features. No obsolete VPN entitlement
is present in the store app. Entitlement generation is not proof of successful
signed sandbox operation; test downloads, file import, AutoFill and website
permissions in the signed archive.

The AppKit regression target exercises first-tab creation, subsequent insertion,
view reuse during reorder, closing tabs and repopulating an empty strip. It
compiles the production tab-strip source without launching a browser session.

## Before upload

This configuration is **release preparation**, not an App Store approval or
submission. Do not upload an unsigned build or substitute the C fallback core.

- Confirm the actual Apple Developer membership, team, agreements and bundle
  registrations in App Store Connect. The source's historical development
  and Developer ID team identifiers differ. Pass the verified team as
  `QWAVE_DEVELOPMENT_TEAM`; do not guess an owner or transfer an identifier.
- The store targets share `is.8b.q-wave` for one Mac/iPhone app record;
  the embedded Mac credential extension uses `is.8b.q-wave.autofill`.
  These differ from the direct-download identifiers. Verify registrations
  and profiles before signing; do not assume existing direct-install data
  or preferences migrate into the store sandbox.
- Configure Apple distribution signing, provisioning, application groups,
  keychain access and the credential-provider entitlement. Do not use the
  empty Developer ID no-VPN entitlements for a store submission.
- The store app manifest declares app-only settings (`CA92.1`), metadata
  in the app container (`C617.1`, the Memory Wave nibble cache), and metadata
  for user-selected files (`3B52.1`, the local document directory browser).
  Audit the final linked SDKs and data collection separately, publish a
  privacy policy, and complete truthful privacy labels. This required-reason
  manifest does not declare that no data is collected. `docs/NETWORK.md`
  describes optional providers and does not replace the collection review.
- Complete screenshots, description, support URL, age-rating questionnaire,
  export-compliance answers and review contact information. Do not guess legal
  declarations or claim private experimental controls are in the store build.
- Run signed Release archives and device checks: navigation, tabs, settings,
  file upload/download, camera/microphone prompts, keyboard, VoiceOver,
  background/restore, offline errors and IPv6-only networking. TestFlight is
  the next distribution checkpoint before public release.
- The current mobile target is **iPhone only**, not a validated iPad layout.
  Its deployment target is iOS 15; that setting does not itself enforce an
  iPhone 13 hardware minimum. A simulator running the newest OS does not
  validate the iOS 15 floor. Default-browser registration needs its own
  entitlement and URL-handling verification.

For archives, use the same generated store project, `-configuration Release`,
the relevant `generic/platform=macOS` or `generic/platform=iOS` destination,
`QWAVE_DEVELOPMENT_TEAM=<verified team>` and `archive`. Do not add
`CODE_SIGNING_ALLOWED=NO` to an archive intended for upload.

Apple references:

- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Required reason APIs](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
- [Current submission requirements](https://developer.apple.com/news/upcoming-requirements/)
- [Create an app record](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app)
