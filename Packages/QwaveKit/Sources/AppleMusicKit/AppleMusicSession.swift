import Foundation
import Combine
#if canImport(MusicKit)
    import MusicKit
#endif

/// The only MusicKit touchpoint in the package. Everything else in
/// AppleMusicKit is pure and compiles without the framework; this file is
/// gated by `canImport(MusicKit)` so the macOS 14 floor and the universal
/// build compile untouched on any SDK — same shape as
/// `Summarize/SummarizeSession.swift`.
///
/// Design rules (see docs/MUSIC.md):
/// - **Never automatic.** Authorization is requested only when the user first
///   opens the Music HUD's affordance, exactly like Summarize is never run
///   speculatively.
/// - **Vanish cleanly.** No subscription, no authorization, or no MusicKit on
///   this build all collapse to `.unavailable`/`.notSubscribed` — never a
///   greyed-out control explaining why.
/// - **Read the system player, don't own one.** Qwave observes whatever is
///   already playing via Apple Music (`SystemMusicPlayer`) and offers
///   transport controls; it does not maintain a private playback queue.
@MainActor
public final class AppleMusicSession: ObservableObject {
    @Published public private(set) var availability: AppleMusicAvailability = .unavailable
    @Published public private(set) var nowPlaying: NowPlayingInfo?

    #if canImport(MusicKit)
        private var playerStateObservers: [Task<Void, Never>] = []
    #endif

    public init() {}

    /// Re-derives `availability` from the current authorization + subscription
    /// state. Call on launch and on foreground; never polled in the
    /// background.
    public func refreshAvailability() async {
        #if canImport(MusicKit)
            if #available(macOS 14.0, *) {
                guard MusicAuthorization.currentStatus == .authorized else {
                    availability = .unavailable
                    return
                }
                do {
                    let subscription = try await MusicSubscription.current
                    availability = subscription.canPlayCatalogContent ? .available : .notSubscribed
                    if availability == .available {
                        startObservingPlayerState()
                    }
                    return
                } catch {
                    availability = .unavailable
                    return
                }
            }
        #endif
        availability = .unavailable
    }

    /// Requests MusicKit authorization. Only ever called from an explicit
    /// user action (opening the HUD affordance for the first time) — never
    /// on launch, never speculatively.
    public func requestAuthorization() async {
        #if canImport(MusicKit)
            if #available(macOS 14.0, *) {
                let status = await MusicAuthorization.request()
                if status == .authorized {
                    await refreshAvailability()
                } else {
                    availability = .unavailable
                }
                return
            }
        #endif
        availability = .unavailable
    }

    public func togglePlayPause() {
        #if canImport(MusicKit)
            if #available(macOS 14.0, *) {
                let player = SystemMusicPlayer.shared
                Task {
                    if player.state.playbackStatus == .playing {
                        player.pause()
                    } else {
                        try? await player.play()
                    }
                }
            }
        #endif
    }

    public func skipToNext() {
        #if canImport(MusicKit)
            if #available(macOS 14.0, *) {
                Task { try? await SystemMusicPlayer.shared.skipToNextEntry() }
            }
        #endif
    }

    public func skipToPrevious() {
        #if canImport(MusicKit)
            if #available(macOS 14.0, *) {
                Task { try? await SystemMusicPlayer.shared.skipToPreviousEntry() }
            }
        #endif
    }

    #if canImport(MusicKit)
        @available(macOS 14.0, *)
        private func startObservingPlayerState() {
            guard playerStateObservers.isEmpty else { return }
            let player = SystemMusicPlayer.shared

            let stateTask = Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(
                    named: MusicPlayer.playbackStateDidChangeNotification
                ) {
                    await self?.syncNowPlaying(from: player)
                }
            }
            let queueTask = Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(
                    named: MusicPlayer.queueDidChangeNotification
                ) {
                    await self?.syncNowPlaying(from: player)
                }
            }
            playerStateObservers = [stateTask, queueTask]
            Task { await syncNowPlaying(from: player) }
        }

        @available(macOS 14.0, *)
        private func syncNowPlaying(from player: SystemMusicPlayer) async {
            guard let entry = player.queue.currentEntry, case let .song(song) = entry.item else {
                nowPlaying = nil
                return
            }
            nowPlaying = NowPlayingInfo(
                title: song.title,
                artist: song.artistName,
                albumTitle: song.albumTitle,
                artworkURL: song.artwork?.url(width: 320, height: 320),
                duration: song.duration,
                elapsed: player.playbackTime,
                status: Self.status(from: player.state.playbackStatus)
            )
        }

        private static func status(from status: MusicPlayer.PlaybackStatus) -> PlaybackStatus {
            switch status {
            case .playing: return .playing
            case .paused: return .paused
            case .interrupted: return .interrupted
            case .seekingForward, .seekingBackward: return .playing
            default: return .stopped
            }
        }
    #endif
}
