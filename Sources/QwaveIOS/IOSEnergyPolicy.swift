// IOSEnergyPolicy.swift — battery state as policy, applied not guessed.
//
// The iPhone lane's battery posture: Low Power Mode and thermal pressure
// collapse into three tiers, and each tier is a concrete, checkable change —
// autoplay requires a gesture, playing media is paused, background tabs are
// evicted sooner. WebKit already suspends off-screen WKWebViews; this policy
// is the part a browser has to decide for itself.

import Foundation
import WebKit

@MainActor
final class IOSEnergyPolicy: ObservableObject {
    enum Tier: Equatable {
        case normal
        /// Low Power Mode, or mild thermal pressure: be frugal.
        case conserve
        /// Serious thermal pressure: media stops, extras go away.
        case critical
    }

    @Published private(set) var tier: Tier = .normal

    /// NotificationCenter tokens. `nonisolated(unsafe)`: only touched from
    /// the main actor except the teardown in `deinit`, which cannot be
    /// isolated.
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    /// The WebKit autoplay policy for new web views under the current tier.
    /// `.audio` (muted autoplay allowed, sound needs a gesture) is the
    /// battery-friendly normal; conserving tiers require a gesture for
    /// everything.
    var autoplayPolicy: WKAudiovisualMediaTypes {
        tier == .normal ? .audio : .all
    }

    /// The maximum number of live tabs under the current tier. Background
    /// tabs beyond this are evicted (their WKWebView is deallocated, so the
    /// page no longer consumes memory or energy).
    var maxLiveTabs: Int {
        switch tier {
        case .normal: return 12
        case .conserve: return 8
        case .critical: return 5
        }
    }

    func install() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.recompute() }
            }
        )
        observers.append(
            center.addObserver(
                forName: .NSProcessInfoPowerStateDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.recompute() }
            }
        )
        recompute()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func recompute() {
        let process = ProcessInfo.processInfo
        switch (process.isLowPowerModeEnabled, process.thermalState) {
        case (_, .critical), (_, .serious):
            tier = .critical
        case (true, _), (_, .fair):
            tier = .conserve
        default:
            tier = .normal
        }
    }

    /// Pauses every playing audio/video element in `webView`. Called when the
    /// tier drops to `.critical`; the JS is inert on pages without media.
    func suspendMedia(in webView: WKWebView) {
        webView.evaluateJavaScript(
            "document.querySelectorAll('video,audio').forEach(function(m){ if(!m.paused){ m.pause(); } });",
            completionHandler: nil
        )
    }
}
