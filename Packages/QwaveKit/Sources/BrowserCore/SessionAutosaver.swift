import Foundation
import Persistence
import QwaveSupport

/// What a session write actually did. Returned by `flushForTermination` so the
/// caller can log a failure rather than discard it — the whole point of not
/// spelling the save `try? await store.save(...)`.
public enum SessionFlushOutcome: Sendable, Equatable {
    /// Written and durable: the file is on disk before this value exists.
    case written
    /// Deliberately not written. The snapshot had no windows, and an empty
    /// session must never overwrite a good one (all windows closed, or only a
    /// private window left — neither contributes persistable tabs).
    case skippedEmpty
    /// The store rejected the write. The autosaver stays dirty so the periodic
    /// floor retries.
    case failed(String)
    /// The write did not finish inside the termination budget, and the caller
    /// was released rather than held. `SessionStore.save` writes atomically, so
    /// the file is still either the previous snapshot or the new one in full —
    /// never a truncated mix.
    case timedOut
}

/// Coalesced, atomic session autosave so a hard crash (or `kill -9`) keeps the
/// last window/tab state instead of only saving at clean termination.
///
/// Two timers, one write path:
/// - a **debounce** timer collapses a burst of navigations/tab churn into a
///   single write shortly after activity settles, and
/// - a **periodic** floor guarantees a save at least every `maxInterval` even
///   under continuous churn (where the debounce would keep resetting).
///
/// Every write goes through `SessionStore.save`, which replaces the file
/// atomically — a crash mid-write can never truncate the session.
///
/// Clean termination is a third, *awaited* path: see `flushForTermination`.
/// It lives here, next to the timers it has to cancel and the empty-snapshot
/// guard it has to honour, rather than being reimplemented by the app delegate.
@MainActor
public final class SessionAutosaver {
    /// How long `flushForTermination` waits for the write before letting the
    /// app quit regardless. Quit has to stay bounded: a stalled volume or a
    /// busy store must delay termination, never wedge it.
    public static let terminationBudget: Duration = .seconds(5)

    private let store: SessionStore
    private let debounce: TimeInterval
    private let maxInterval: TimeInterval
    private let snapshot: @MainActor () -> SessionSnapshot

    private var debounceTimer: DispatchSourceTimer?
    private var periodicTimer: DispatchSourceTimer?
    /// A save-worthy change happened since the last flush.
    private var dirty = false

    public init(
        store: SessionStore,
        debounce: TimeInterval = 2,
        maxInterval: TimeInterval = 30,
        snapshot: @escaping @MainActor () -> SessionSnapshot
    ) {
        self.store = store
        self.debounce = debounce
        self.maxInterval = maxInterval
        self.snapshot = snapshot
        startPeriodicTimer()
    }

    /// Note a session-relevant change; schedules a debounced save.
    public func requestSave() {
        dirty = true
        debounceTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + debounce, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.flush() }
        timer.resume()
        debounceTimer = timer
    }

    /// The clean-termination path: take a final snapshot and **wait** for it to
    /// reach disk.
    ///
    /// Unlike the timer-driven `flush`, this does not hand the write to an
    /// unawaited `Task` — when it returns `.written` the bytes are already on
    /// disk, so the caller may let the process go away. AppKit's shape for that
    /// is `applicationShouldTerminate` returning `.terminateLater` and calling
    /// `reply(toApplicationShouldTerminate:)` once this resolves.
    ///
    /// It snapshots unconditionally rather than checking `dirty`: a quit is
    /// cheap and rare, and this way the last state on screen is the last state
    /// on disk even if some change never routed through `requestSave`.
    public func flushForTermination(
        timeout: Duration = SessionAutosaver.terminationBudget
    ) async -> SessionFlushOutcome {
        // Drop the pending debounce so it cannot fire a second, *unawaited*
        // write behind this one while termination is being held.
        debounceTimer?.cancel()
        debounceTimer = nil

        let snapshot = self.snapshot()
        // Never clobber a good saved session with an empty one.
        guard !snapshot.windows.isEmpty else { return .skippedEmpty }
        dirty = false

        let store = self.store
        let outcome = await Self.withTerminationBudget(timeout) {
            do {
                try await store.save(snapshot)
                return .written
            } catch {
                return .failed(String(describing: error))
            }
        }
        switch outcome {
        case .written, .skippedEmpty:
            break
        case .failed(let message):
            QwaveLog.persistence.error(
                "Session save at termination failed: \(message, privacy: .public)")
            dirty = true
        case .timedOut:
            QwaveLog.persistence.error(
                "Session save at termination exceeded its budget; quitting anyway")
            dirty = true
        }
        return outcome
    }

    public func stop() {
        debounceTimer?.cancel()
        debounceTimer = nil
        periodicTimer?.cancel()
        periodicTimer = nil
    }

    /// Await `work`, but give up *waiting* after `timeout` — the work itself
    /// keeps running.
    ///
    /// `work` runs in an **unstructured** task on purpose. `SessionStore.save`
    /// is a synchronous actor method, so once it starts it cannot be cancelled;
    /// a structured child would make `withTaskGroup` wait for it no matter what
    /// the timeout said, which is exactly the quit-time hang this budget exists
    /// to prevent.
    static func withTerminationBudget(
        _ timeout: Duration,
        _ work: @escaping @Sendable () async -> SessionFlushOutcome
    ) async -> SessionFlushOutcome {
        let (stream, continuation) = AsyncStream<SessionFlushOutcome>.makeStream()
        Task.detached(priority: .userInitiated) {
            continuation.yield(await work())
        }
        let timer = Task.detached(priority: .userInitiated) {
            try? await Task.sleep(for: timeout)
            continuation.yield(.timedOut)
        }
        defer { timer.cancel() }
        for await outcome in stream {
            return outcome
        }
        return .timedOut
    }

    private func startPeriodicTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + maxInterval, repeating: maxInterval, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            guard let self, self.dirty else { return }
            self.flush()
        }
        timer.resume()
        periodicTimer = timer
    }

    private func flush() {
        debounceTimer?.cancel()
        debounceTimer = nil
        guard dirty else { return }
        dirty = false
        let snapshot = self.snapshot()
        // Never clobber a good saved session with an empty one — e.g. only a
        // private window is open, which contributes no persistable tabs.
        guard !snapshot.windows.isEmpty else { return }
        let store = self.store
        Task { [weak self] in
            do {
                try await store.save(snapshot)
            } catch {
                // Not `try?`: a session write that fails silently is how a user
                // loses a session and never learns why. Log it, and go back to
                // dirty so the periodic floor and the termination flush retry.
                QwaveLog.persistence.error(
                    "Session autosave failed: \(String(describing: error), privacy: .public)")
                self?.dirty = true
            }
        }
    }
}
