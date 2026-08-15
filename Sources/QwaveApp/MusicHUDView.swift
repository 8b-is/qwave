import SwiftUI
import AppleMusicKit

/// The Music HUD: a compact "now playing" pill that lives in the toolbar
/// next to the omnibox, and only exists while `MusicHUDPresenceMachine` says
/// it should — see `refreshMusicHUDPresence()` in `BrowserWindowController`.
/// Nothing here can act on the browser: it reads Apple Music's system player
/// and offers play/pause/skip, and that's the entire surface.
struct MusicHUDView: View {
    var nowPlaying: NowPlayingInfo
    var onTogglePlayPause: () -> Void
    var onNext: () -> Void
    var onPrevious: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            artwork
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)

            VStack(alignment: .leading, spacing: 0) {
                Text(nowPlaying.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(nowPlaying.artist)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: 130, alignment: .leading)
            .id(nowPlaying.title + nowPlaying.artist)
            .transition(.opacity.combined(with: .move(edge: .top)))

            HStack(spacing: 2) {
                hudButton(symbol: "backward.fill", action: onPrevious, accessibilityLabel: "Previous")
                hudButton(
                    symbol: nowPlaying.isPlaying ? "pause.fill" : "play.fill",
                    action: onTogglePlayPause,
                    accessibilityLabel: nowPlaying.isPlaying ? "Pause" : "Play"
                )
                hudButton(symbol: "forward.fill", action: onNext, accessibilityLabel: "Next")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(.thinMaterial)
                .overlay(Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: nowPlaying.title)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: nowPlaying.isPlaying)
        .fixedSize()
    }

    @ViewBuilder
    private var artwork: some View {
        if let url = nowPlaying.artworkURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                        .transition(.opacity)
                default:
                    artworkPlaceholder
                }
            }
        } else {
            artworkPlaceholder
        }
    }

    private var artworkPlaceholder: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color.secondary.opacity(0.18))
            .overlay(Image(systemName: "music.note").font(.system(size: 10)).foregroundStyle(.secondary))
    }

    private func hudButton(symbol: String, action: @escaping () -> Void, accessibilityLabel: String) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Toolbar-hosted wrapper: decides, from `AppleMusicSession`'s published
/// state, whether the HUD exists at all — vanish-cleanly, same rule as
/// `SummarizePresenceMachine`. The pop-in/pop-out itself is what makes the
/// top bar feel alive rather than just present-or-absent: a scale+opacity
/// spring, matching the smoothness of Control Center's Now Playing widget.
struct MusicHUDContainerView: View {
    @ObservedObject var session: AppleMusicSession

    private var shouldShow: Bool {
        MusicHUDPresenceMachine.shouldShowHUD(availability: session.availability, nowPlaying: session.nowPlaying)
    }

    var body: some View {
        Group {
            if shouldShow, let nowPlaying = session.nowPlaying {
                MusicHUDView(
                    nowPlaying: nowPlaying,
                    onTogglePlayPause: session.togglePlayPause,
                    onNext: session.skipToNext,
                    onPrevious: session.skipToPrevious
                )
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.85, anchor: .leading).combined(with: .opacity),
                    removal: .opacity
                ))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: shouldShow)
        .fixedSize()
    }
}
