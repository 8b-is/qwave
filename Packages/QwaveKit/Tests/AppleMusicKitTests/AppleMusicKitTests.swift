import XCTest
@testable import AppleMusicKit

/// Pure-core tests. No MusicKit, no live subscription, no system player:
/// this suite runs on any Mac and any SDK — mirrors `SummarizePolicyTests`.
final class AppleMusicKitTests: XCTestCase {
    // MARK: NowPlayingInfo

    func testFractionCompleteClampsToUnitRange() {
        var info = NowPlayingInfo(title: "A", artist: "B", duration: 100, elapsed: 40)
        XCTAssertEqual(info.fractionComplete, 0.4)

        info.elapsed = 250
        XCTAssertEqual(info.fractionComplete, 1)

        info.elapsed = -5
        XCTAssertEqual(info.fractionComplete, 0)
    }

    func testFractionCompleteNilWithoutDuration() {
        let info = NowPlayingInfo(title: "A", artist: "B", elapsed: 10)
        XCTAssertNil(info.fractionComplete)
    }

    func testIsPlayingReflectsStatus() {
        var info = NowPlayingInfo(title: "A", artist: "B", status: .playing)
        XCTAssertTrue(info.isPlaying)
        info.status = .paused
        XCTAssertFalse(info.isPlaying)
    }

    // MARK: MusicHUDPresenceMachine — vanish-cleanly rules

    func testHUDHiddenWithoutSubscription() {
        let info = NowPlayingInfo(title: "A", artist: "B", status: .playing)
        XCTAssertFalse(MusicHUDPresenceMachine.shouldShowHUD(availability: .notSubscribed, nowPlaying: info))
        XCTAssertFalse(MusicHUDPresenceMachine.shouldShowHUD(availability: .unavailable, nowPlaying: info))
    }

    func testHUDHiddenWithoutNowPlaying() {
        XCTAssertFalse(MusicHUDPresenceMachine.shouldShowHUD(availability: .available, nowPlaying: nil))
    }

    func testHUDShownWhenSubscribedAndPlayingOrPaused() {
        let playing = NowPlayingInfo(title: "A", artist: "B", status: .playing)
        let paused = NowPlayingInfo(title: "A", artist: "B", status: .paused)
        XCTAssertTrue(MusicHUDPresenceMachine.shouldShowHUD(availability: .available, nowPlaying: playing))
        XCTAssertTrue(MusicHUDPresenceMachine.shouldShowHUD(availability: .available, nowPlaying: paused))
    }

    func testHUDHiddenWhenStoppedOrInterrupted() {
        let stopped = NowPlayingInfo(title: "A", artist: "B", status: .stopped)
        let interrupted = NowPlayingInfo(title: "A", artist: "B", status: .interrupted)
        XCTAssertFalse(MusicHUDPresenceMachine.shouldShowHUD(availability: .available, nowPlaying: stopped))
        XCTAssertFalse(MusicHUDPresenceMachine.shouldShowHUD(availability: .available, nowPlaying: interrupted))
    }

    // MARK: NowPlayingTimeFormatter

    func testTimeFormatting() {
        XCTAssertEqual(NowPlayingTimeFormatter.format(0), "0:00")
        XCTAssertEqual(NowPlayingTimeFormatter.format(65), "1:05")
        XCTAssertEqual(NowPlayingTimeFormatter.format(3_661), "61:01")
    }

    func testTimeFormattingRejectsNonFinite() {
        XCTAssertEqual(NowPlayingTimeFormatter.format(.infinity), "0:00")
        XCTAssertEqual(NowPlayingTimeFormatter.format(.nan), "0:00")
        XCTAssertEqual(NowPlayingTimeFormatter.format(-3), "0:00")
    }
}
