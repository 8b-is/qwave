import XCTest
import WebKit
import Darwin
@testable import BrowserCore
import Shields
import FeatureFlags
import Persistence

/// Proves the hibernation claim instead of asserting it: the memory a
/// hibernated tab frees lives in WebKit's OUT-OF-PROCESS WebContent
/// processes, which no in-process metric can see.
///
/// The claim splits into two halves that behave completely differently, and
/// #142 was the result of gating on both as if they were one:
///
/// - **What Qwave controls**, and therefore what a Qwave regression can
///   break: hibernating tears the web view down, captures enough to wake
///   from, and drops the last reference — so the content process is
///   *released*. That is deterministic, and it gates.
/// - **What WebKit and the kernel control**: when the released process is
///   actually reaped and its pages returned. That is scheduled by someone
///   else, is not synchronous with the hibernate call, and under machine
///   contention had reclaimed ~4.8 MB of an expected >31 MB after twenty
///   seconds of polling. It is measured, printed, and does not gate.
@MainActor
final class HibernationReclaimTests: XCTestCase {
    /// Opt-in switch for the byte-level measurement below.
    private static let measurementEnvironmentKey = "QWAVE_MEASURE_HIBERNATION_RECLAIM"

    // MARK: - Process-tree metering

    private enum ProcessMeter {
        static func webContentPIDs() -> Set<pid_t> {
            var size = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
            guard size > 0 else { return [] }
            var pids = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.size + 64)
            size = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
            let count = Int(size) / MemoryLayout<pid_t>.size
            var result: Set<pid_t> = []
            var nameBuffer = [CChar](repeating: 0, count: 1024)
            for pid in pids.prefix(count) where pid > 0 {
                nameBuffer[0] = 0
                _ = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
                let processName = nameBuffer.withUnsafeBufferPointer { ptr in
                    ptr.baseAddress.map { String(cString: $0) } ?? ""
                }
                if processName == "com.apple.WebKit.WebContent" {
                    result.insert(pid)
                }
            }
            return result
        }

        /// Sum of `ri_phys_footprint` (the number Activity Monitor shows)
        /// over live pids; dead pids contribute zero.
        static func footprint(of pids: Set<pid_t>) -> UInt64 {
            var total: UInt64 = 0
            for pid in pids {
                var usage = rusage_info_current()
                let ok = withUnsafeMutablePointer(to: &usage) { ptr -> Int32 in
                    ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reptr in
                        proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, reptr)
                    }
                }
                if ok == 0 {
                    total += usage.ri_phys_footprint
                }
            }
            return total
        }
    }

    /// Non-owning handle used to observe that the last strong reference to a
    /// web view really went away.
    private final class WeakWebView {
        weak var value: WKWebView?
        init(_ value: WKWebView) { self.value = value }
    }

    // MARK: - Fixture

    /// ~24 MB of JS-held doubles plus real DOM, so each page's content
    /// process carries measurable, deterministic ballast. Local file only.
    private func writeBallastPage(index: Int) throws -> URL {
        let html = """
            <!doctype html><html><head><meta charset="utf-8"><title>ballast \(index)</title></head>
            <body><h1>ballast \(index)</h1>
            <script>
              window.ballast = new Array(3 * 1024 * 1024).fill(0.123456789 + \(index));
              for (let i = 0; i < 2000; i++) {
                const p = document.createElement('p');
                p.textContent = 'paragraph ' + i + ' of ballast page \(index)';
                document.body.appendChild(p);
              }
              document.title = 'ready-\(index)';
            </script></body></html>
            """
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwave-hibernation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ballast-\(index).html")
        try Data(html.utf8).write(to: url)
        return url
    }

    private func makeFactory() -> WebViewFactory {
        WebViewFactory(
            containers: ContainerRegistry(directory: nil),
            shields: ShieldsDirector(compiler: RuleListCompiler(), policy: ShieldsPolicy(directory: nil)),
            featureFlags: FeatureFlagService(),
            settings: SettingsStore()
        )
    }

    private func waitUntil(
        timeout: TimeInterval,
        _ condition: @MainActor () -> Bool
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }

    /// Builds `tabCount` tabs on real ballast pages and waits for them to load.
    private func loadBallastTabs(
        count: Int,
        factory: WebViewFactory
    ) async throws -> (tabs: [Tab], webViews: [WKWebView]) {
        var tabs: [Tab] = []
        var webViews: [WKWebView] = []
        for index in 0..<count {
            let fileURL = try writeBallastPage(index: index)
            let tab = Tab(pendingURL: fileURL)
            let webView = factory.makeWebView(for: tab)
            tab.attach(webView: webView)
            webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
            tabs.append(tab)
            webViews.append(webView)
        }
        for (index, webView) in webViews.enumerated() {
            let loaded = try await waitUntil(timeout: 60) {
                webView.title == "ready-\(index)"
            }
            XCTAssertTrue(loaded, "ballast page \(index) did not finish loading")
        }
        return (tabs, webViews)
    }

    // MARK: - Gating: what hibernation is actually responsible for

    /// Blocking, and deterministic under any load: hibernating captures what
    /// it needs, drops the web view, and releases it — after which the content
    /// process belongs to nobody but WebKit. Waking brings the page back.
    ///
    /// The dropped-reference assertion is the one that matters. Reclamation is
    /// impossible while Qwave still holds the `WKWebView`, so a regression that
    /// leaks it — a stray strong capture in a delegate or an energy timer —
    /// fails here immediately, with no dependence on when the kernel gets round
    /// to reaping anything.
    func testHibernationReleasesTheContentProcessAndWakeRestores() async throws {
        let tabCount = 3
        let factory = makeFactory()
        let hibernator = TabHibernator(factory: factory)

        var (tabs, webViews) = try await loadBallastTabs(count: tabCount, factory: factory)
        let observers = webViews.map(WeakWebView.init)

        for tab in tabs {
            await hibernator.hibernate(tab)
            XCTAssertTrue(tab.isHibernated)
            XCTAssertNil(tab.webView, "hibernated tab must hold no WKWebView")
            XCTAssertNotNil(
                tab.hibernationRecord?.url, "hibernation must capture the URL to wake from")
        }

        // Drop the test's own references; the tabs already dropped theirs.
        webViews.removeAll()
        let released = try await waitUntil(timeout: 30) {
            observers.allSatisfy { $0.value == nil }
        }
        XCTAssertTrue(
            released,
            "every hibernated tab's WKWebView must be deallocated — while one is alive its content process cannot be reclaimed at all"
        )

        // Wake: the cost the user pays for the memory. Correctness gates here;
        // the latency *number* is in the measurement below, since it is as
        // load-sensitive as the footprint is.
        let wakeTab = tabs[0]
        let restored = hibernator.restore(wakeTab)
        wakeTab.attach(webView: restored)
        if let pending = wakeTab.pendingURL ?? wakeTab.hibernationRecord?.url {
            restored.loadFileURL(pending, allowingReadAccessTo: pending.deletingLastPathComponent())
        }
        let woke = try await waitUntil(timeout: 60) {
            restored.title == "ready-0"
        }
        XCTAssertTrue(woke, "restored tab must reload its page")
    }

    // MARK: - Measured, not gated: the bytes the OS gives back

    /// The byte-level proof that hibernation returns real memory.
    ///
    /// **Deliberately off the blocking job** (#142). The assertions below are
    /// unchanged and deliberately strict — the fix for the flake was never to
    /// loosen them to whatever passes under load, because the threshold is the
    /// entire content of the test. What changed is that the result depends on
    /// WebKit's process-cache eviction and the kernel's reaping schedule, and
    /// gating a merge on another process's scheduling decisions produces
    /// exactly the spurious red that teaches people to re-run this job.
    ///
    /// Run it on a quiet machine:
    ///
    ///     QWAVE_MEASURE_HIBERNATION_RECLAIM=1 \
    ///       swift test --package-path Packages/QwaveKit -c release \
    ///       --filter testHibernationReclaimsContentProcessMemory
    func testHibernationReclaimsContentProcessMemory() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment[Self.measurementEnvironmentKey] == "1",
            "Byte-level reclamation measurement — set \(Self.measurementEnvironmentKey)=1 and run on an idle machine (see #142)."
        )

        let tabCount = 3
        let factory = makeFactory()
        let hibernator = TabHibernator(factory: factory)

        let baselinePIDs = ProcessMeter.webContentPIDs()
        var (tabs, webViews) = try await loadBallastTabs(count: tabCount, factory: factory)

        // Let allocations and process bookkeeping settle.
        try await Task.sleep(nanoseconds: 2_000_000_000)

        let ourPIDs = ProcessMeter.webContentPIDs().subtracting(baselinePIDs)
        XCTAssertFalse(ourPIDs.isEmpty, "expected the test's own WebContent process(es)")
        let before = ProcessMeter.footprint(of: ourPIDs)
        XCTAssertGreaterThan(before, 0)

        for tab in tabs {
            await hibernator.hibernate(tab)
        }
        webViews.removeAll()

        // WebKit tears content processes down asynchronously, on its own
        // schedule. Poll generously — this no longer costs the blocking job
        // anything, so the deadline can be as patient as it needs to be.
        _ = try await waitUntil(timeout: 60) {
            ProcessMeter.footprint(of: ourPIDs) < before / 2
        }
        let after = ProcessMeter.footprint(of: ourPIDs)
        let reclaimed = before - min(after, before)

        let mb = { (bytes: UInt64) in String(format: "%.1f", Double(bytes) / 1_048_576) }
        print(
            "[hibernation-reclaim] processes=\(ourPIDs.count) before=\(mb(before))MB after=\(mb(after))MB reclaimed=\(mb(reclaimed))MB (\(mb(reclaimed / UInt64(tabCount)))MB/tab)"
        )

        XCTAssertLessThan(
            after, before / 2,
            "hibernating every tab must reclaim most of the content-process footprint"
        )
        XCTAssertGreaterThan(
            reclaimed, UInt64(tabCount) * 10 * 1_048_576,
            "with ~24MB ballast per page, expect >10MB reclaimed per tab"
        )

        // Wake latency: the cost the user pays for the memory.
        let wakeTab = tabs[0]
        let wakeStart = ContinuousClock.now
        let restored = hibernator.restore(wakeTab)
        wakeTab.attach(webView: restored)
        if let pending = wakeTab.pendingURL ?? wakeTab.hibernationRecord?.url {
            restored.loadFileURL(pending, allowingReadAccessTo: pending.deletingLastPathComponent())
        }
        let woke = try await waitUntil(timeout: 30) {
            restored.title == "ready-0"
        }
        let wakeElapsed = ContinuousClock.now - wakeStart
        let wakeMS =
            Double(wakeElapsed.components.seconds) * 1000
            + Double(wakeElapsed.components.attoseconds) / 1e15
        print("[hibernation-reclaim] wake-to-interactive: \(Int(wakeMS))ms")
        XCTAssertTrue(woke, "restored tab must reload its page")
        XCTAssertLessThan(wakeMS, 10_000, "wake latency out of hand")
    }
}
