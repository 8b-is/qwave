import XCTest
import Persistence
@testable import BrowserCore

/// Covers the **termination path**, not `flushNow()` in isolation.
///
/// The distinction is the whole bug (#145): the old clean-termination flush
/// ended in `Task { try? await store.save(snapshot) }` — detached, unawaited,
/// error discarded. An assertion that "flushing writes eventually" passed
/// against that code and proved nothing. These tests instead assert what
/// termination actually needs: that when the flush *returns*, the process is
/// safe to kill, because the bytes are already on disk.
@MainActor
final class SessionTerminationTests: XCTestCase {
    /// Mutable snapshot source, standing in for the app delegate's live window
    /// controllers.
    @MainActor
    private final class SnapshotSource {
        var snapshot: SessionSnapshot = SessionSnapshot(windows: [])
    }

    private func makeStore() async throws -> (SessionStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwave-session-term-\(UUID().uuidString)", isDirectory: true)
        return (try await SessionStore(directory: directory), directory)
    }

    private func session(url: String, title: String) -> SessionSnapshot {
        SessionSnapshot(windows: [
            WindowSnapshot(
                tabs: [
                    TabSnapshot(
                        url: URL(string: url), title: title, containerID: nil, isPinned: false)
                ],
                selectedIndex: 0
            )
        ])
    }

    // MARK: - The regression

    /// Quit inside the 2 s debounce window of the last change. When the
    /// termination flush returns, that change must already be readable from
    /// disk — nothing further gets to run before the process dies.
    func testTerminationFlushIsDurableBeforeItReturns() async throws {
        let (store, directory) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = SnapshotSource()
        source.snapshot = session(url: "https://example.com/last-thing-i-did", title: "Last thing")

        let autosaver = SessionAutosaver(
            store: store, debounce: 2, maxInterval: 3600, snapshot: { source.snapshot })

        // A session-relevant change, then an immediate quit: well inside the
        // debounce, so the timer-driven write has certainly not fired.
        autosaver.requestSave()

        let outcome = await autosaver.flushForTermination()
        XCTAssertEqual(outcome, .written)

        // No sleep, no polling, no second chance: exactly the guarantee the
        // termination path has to provide.
        let persisted = await store.load()
        XCTAssertEqual(
            persisted?.windows.first?.tabs.first?.url,
            URL(string: "https://example.com/last-thing-i-did"),
            "the change made inside the debounce window must survive quitting"
        )
    }

    /// The guard that makes this fix safe to ship: quitting must never write an
    /// empty session over a good one. The app stays alive with zero windows
    /// (`applicationShouldTerminateAfterLastWindowClosed` is false) and a
    /// private-only window contributes no persistable tabs, so an empty
    /// snapshot at quit time is normal, not a signal to erase the session.
    func testTerminationFlushNeverClobbersGoodSessionWithEmptyOne() async throws {
        let (store, directory) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let good = session(url: "https://example.com/yesterday", title: "Yesterday")
        try await store.save(good)

        let source = SnapshotSource()
        source.snapshot = SessionSnapshot(windows: [])
        let autosaver = SessionAutosaver(
            store: store, debounce: 2, maxInterval: 3600, snapshot: { source.snapshot })
        autosaver.requestSave()

        let outcome = await autosaver.flushForTermination()
        XCTAssertEqual(outcome, .skippedEmpty)

        let persisted = await store.load()
        XCTAssertEqual(
            persisted?.windows.first?.tabs.first?.url,
            URL(string: "https://example.com/yesterday"),
            "an empty snapshot at quit must not erase the restorable session"
        )
    }

    /// A failing write must be reported, not swallowed. The old path spelled
    /// this `try?`, which is how a user loses a session and never learns why.
    func testTerminationFlushReportsAFailedWriteInsteadOfSwallowingIt() async throws {
        let (store, directory) = try await makeStore()

        // Remove the directory the store was told to write into: the atomic
        // write now fails, with no way for the store to recover.
        try FileManager.default.removeItem(at: directory)

        let source = SnapshotSource()
        source.snapshot = session(url: "https://example.com/doomed", title: "Doomed")
        let autosaver = SessionAutosaver(
            store: store, debounce: 2, maxInterval: 3600, snapshot: { source.snapshot })
        autosaver.requestSave()

        let outcome = await autosaver.flushForTermination()
        switch outcome {
        case .failed:
            break
        default:
            XCTFail("a write that cannot land must surface as .failed, got \(outcome)")
        }
    }

    // MARK: - Quit must stay bounded

    /// `.terminateLater` hands the app's life to whoever calls `reply`. If the
    /// store stalls, the budget has to release the caller anyway — a quit that
    /// hangs forever is worse than the bug this PR fixes.
    ///
    /// This drives the same helper the real flush uses, with work that never
    /// finishes in time.
    func testTerminationBudgetReleasesTheCallerWhenTheStoreStalls() async {
        let start = ContinuousClock.now
        let outcome = await SessionAutosaver.withTerminationBudget(.milliseconds(200)) {
            try? await Task.sleep(for: .seconds(30))
            return .written
        }
        let elapsed = ContinuousClock.now - start

        XCTAssertEqual(outcome, .timedOut)
        XCTAssertLessThan(
            elapsed, .seconds(5), "the budget must release quit, not wait for the stalled write")
    }

    /// The budget must not cost anything when the store is healthy.
    func testTerminationBudgetReturnsImmediatelyWhenTheWriteIsFast() async {
        let start = ContinuousClock.now
        let outcome = await SessionAutosaver.withTerminationBudget(.seconds(30)) { .written }
        let elapsed = ContinuousClock.now - start

        XCTAssertEqual(outcome, .written)
        XCTAssertLessThan(elapsed, .seconds(5))
    }
}
