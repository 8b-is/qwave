# Apple Music HUD — design

One-page contract for the Now Playing HUD, in the shape of
[docs/SUMMARIZE.md](SUMMARIZE.md): **Optional · Read-only · vanish-cleanly**,
and "never automatic, never speculative, never a second player."

## What it is

A compact "now playing" pill that lives in the toolbar (the top bar), next to
the omnibox, whenever you have an active Apple Music subscription **and**
something is playing. It shows artwork, title, artist, and play/pause/skip
transport controls, and animates in and out with the same spring-based
smoothness as Control Center's Now Playing widget — a scale-and-fade pop-in,
a crossfade on track change, nothing that jumps.

It reads the system's Apple Music player (`SystemMusicPlayer`, via
`MusicKit`). It does not run its own playback queue, does not stream audio
itself, and cannot navigate the browser or touch tab state — the entire
surface is "what's playing" plus "play/pause/skip".

## Hard rules

1. **Subscription-gated, not just authorization-gated.** The HUD requires
   both MusicKit authorization *and* `MusicSubscription.current.canPlayCatalogContent`
   (`AppleMusicSession.refreshAvailability`, `AppleMusicKit/AppleMusicSession.swift`).
   No subscription collapses to `.notSubscribed`, which — like Summarize's
   `.unavailable` — renders nothing. No greyed-out control nagging you to
   subscribe.
2. **Never automatic.** `MusicAuthorization.request()` (the call that can show
   an OS permission sheet) is only ever invoked from an explicit user action —
   never at launch, never speculatively. Launch only calls
   `refreshAvailability()`, which reads `MusicAuthorization.currentStatus`
   without prompting; if you have never granted access, the HUD simply stays
   absent (`BrowserEnvironment.bootstrap`).
3. **Presence needs both a subscription and something to show.** A
   subscription alone does not show the HUD — `MusicHUDPresenceMachine.shouldShowHUD`
   additionally requires a `NowPlayingInfo` in `.playing` or `.paused` state.
   Stopped or interrupted playback hides the HUD exactly like a track ending.
   This is a pure function (`NowPlaying.swift`), tested without any live
   player in `AppleMusicKitTests`.
4. **Read the system player, don't own one.** Qwave never builds a private
   `ApplicationMusicPlayer` queue or plays catalog content on your behalf; it
   only observes and controls whatever Apple Music (or another app driving
   `SystemMusicPlayer`) is already doing. Skip/previous/play/pause are the
   only mutating calls the HUD makes.
5. **MusicKit isolation.** `AppleMusicSession` is the *only* file in
   `AppleMusicKit` that imports `MusicKit`, gated by
   `#if canImport(MusicKit)` / `@available(macOS 14.0, *)` — same shape as
   `Summarize/SummarizeSession.swift`'s `FoundationModels` isolation. Every
   other type in the package (`NowPlayingInfo`, `MusicHUDPresenceMachine`,
   `NowPlayingTimeFormatter`) is pure Foundation and compiles/tests on any Mac
   and any SDK.

## What it is not

- Not a music player. No search, no library browsing, no catalog playback
  Qwave initiates.
- Not a second source of truth for playback state — it mirrors the system
  player and gets out of the way the moment nothing is playing.
- Not network-audited by Qwave's egress allowlist. MusicKit's traffic (a
  subscription check, artwork, catalog metadata) goes through Apple's own
  system framework, the same category as the Safe Browsing check in
  [docs/NETWORK.md](NETWORK.md)'s Category C — Qwave's code decides to ask,
  but the wire traffic itself is Apple's, not Qwave's `URLSession`. See the
  Category A row there for the disclosure.

## Architecture

- `Packages/QwaveKit/Sources/AppleMusicKit/NowPlaying.swift` — pure models:
  `NowPlayingInfo`, `PlaybackStatus`, `AppleMusicAvailability`,
  `MusicHUDPresenceMachine`, `NowPlayingTimeFormatter`.
- `Packages/QwaveKit/Sources/AppleMusicKit/AppleMusicSession.swift` — the
  MusicKit touchpoint: authorization/subscription checks, `SystemMusicPlayer`
  observation via `MusicPlayer.playbackStateDidChangeNotification` /
  `queueDidChangeNotification`, and transport controls.
- `Sources/QwaveApp/MusicHUDView.swift` — the SwiftUI HUD (`MusicHUDView`) and
  its presence wrapper (`MusicHUDContainerView`), which decides whether
  anything renders at all.
- `Sources/QwaveApp/BrowserWindowController.swift` — hosts the HUD as a
  toolbar item (`qwave.musicHUD`) next to the omnibox, one
  `AppleMusicSession` shared across windows (`BrowserEnvironment.appleMusic`)
  since it mirrors a single system player, not per-window state.

## Entitlements

`com.apple.developer.musickit` (Qwave.entitlements) and
`NSAppleMusicUsageDescription` (Info.plist) — enforced only when signed with a
real team ID, same posture as the VPN/AutoFill entitlements (see
[docs/SIGNING.md](SIGNING.md)).
