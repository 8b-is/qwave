import Foundation
import Persistence
import QwaveSupport

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
@MainActor
final class SessionAutosaver {
    private let store: SessionStore
    private let debounce: TimeInterval
    private let maxInterval: TimeInterval
    private let snapshot: @MainActor () -> SessionSnapshot

    private var debounceTimer: DispatchSourceTimer?
    private var periodicTimer: DispatchSourceTimer?
    /// A save-worthy change happened since the last flush.
    private var dirty = false

    init(
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
    func requestSave() {
        dirty = true
        debounceTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + debounce, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.flush() }
        timer.resume()
        debounceTimer = timer
    }

    /// Write immediately if anything is pending (clean-termination path).
    func flushNow() {
        flush()
    }

    func stop() {
        debounceTimer?.cancel()
        debounceTimer = nil
        periodicTimer?.cancel()
        periodicTimer = nil
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
        Task { try? await store.save(snapshot) }
    }
}
