import Foundation

/// Playback state of the system music player, distilled from MusicKit's
/// `MusicPlayer.PlaybackStatus` by `AppleMusicSession` (the only file that
/// touches the framework). Kept dependency-free so this file compiles and
/// tests on any Mac and any SDK.
public enum PlaybackStatus: Equatable, Sendable {
    case playing
    case paused
    case stopped
    case interrupted
}

/// One song's worth of state for the HUD. Deliberately minimal: title,
/// artist, artwork, and enough playback state to drive a progress bar and a
/// play/pause glyph — nothing that would let the HUD grow into a second
/// player UI.
public struct NowPlayingInfo: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var albumTitle: String?
    public var artworkURL: URL?
    public var duration: TimeInterval?
    public var elapsed: TimeInterval
    public var status: PlaybackStatus

    public init(
        title: String,
        artist: String,
        albumTitle: String? = nil,
        artworkURL: URL? = nil,
        duration: TimeInterval? = nil,
        elapsed: TimeInterval = 0,
        status: PlaybackStatus = .stopped
    ) {
        self.title = title
        self.artist = artist
        self.albumTitle = albumTitle
        self.artworkURL = artworkURL
        self.duration = duration
        self.elapsed = elapsed
        self.status = status
    }

    public var isPlaying: Bool { status == .playing }

    /// `0...1`, or `nil` when the duration is unknown (radio-style streams).
    /// Clamped so a stale `elapsed` sample never pushes the HUD's progress
    /// ring past full or negative.
    public var fractionComplete: Double? {
        guard let duration, duration > 0 else { return nil }
        return min(1, max(0, elapsed / duration))
    }
}

/// Whether Apple Music playback data should ever be shown, distilled from
/// `MusicSubscription.current` + `MusicAuthorization.currentStatus` by
/// `AppleMusicSession`. Three states, deliberately — see `SummarizeAvailability`
/// for the precedent this mirrors:
/// - `.available` → subscribed and authorized; the HUD may appear.
/// - `.notSubscribed` → authorized but no active Apple Music subscription;
///   vanish cleanly, never a greyed-out HUD nagging to subscribe.
/// - `.unavailable` → not authorized, or MusicKit unreachable on this build.
public enum AppleMusicAvailability: Equatable, Sendable {
    case available
    case notSubscribed
    case unavailable
}

/// Pure presence state machine — mirrors `SummarizePresenceMachine`. The HUD
/// is never shown just because a subscription exists: it also needs an
/// active `NowPlayingInfo` (nothing plays automatically, nothing appears
/// speculatively).
public enum MusicHUDPresenceMachine {
    public static func shouldShowHUD(
        availability: AppleMusicAvailability,
        nowPlaying: NowPlayingInfo?
    ) -> Bool {
        guard availability == .available, let nowPlaying else { return false }
        return nowPlaying.status == .playing || nowPlaying.status == .paused
    }
}

/// `MM:SS` formatting for the HUD's scrubber labels. Pure so it's testable
/// without a running player.
public enum NowPlayingTimeFormatter {
    public static func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
