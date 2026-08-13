import XCTest
import WebKit
import Darwin
@testable import BrowserCore
import Shields
import FeatureFlags
import Persistence

/// Proves the hibernation claim instead of asserting it: the memory a
/// hibernated tab frees lives in WebKit's OUT-OF-PROCESS WebContent
/// processes, which no in-process metric can see. This test measures the
/// process tree directly — it snapshots the set of `com.apple.WebKit.
/// WebContent` pids before creating web views (so other apps' WebKit
/// processes are excluded by set difference), sums their physical
/// footprint via `proc_pid_rusage`, hibernates every tab, and asserts the
/// footprint actually falls. Pages load from local files only.
@MainActor
final class HibernationReclaimTests: XCTestCase {
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
                if String(cString: nameBuffer) == "com.apple.WebKit.WebContent" {
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

    // MARK: - The measurement

    func testHibernationReclaimsContentProcessMemoryAndWakeRestores() async throws {
        let tabCount = 3
        let factory = makeFactory()
        let hibernator = TabHibernator(factory: factory)

        let baselinePIDs = ProcessMeter.webContentPIDs()

        var tabs: [Tab] = []
        var webViews: [WKWebView] = []
        for index in 0..<tabCount {
            let fileURL = try writeBallastPage(index: index)
            let tab = Tab(pendingURL: fileURL)
            let webView = factory.makeWebView(for: tab)
            tab.attach(webView: webView)
            webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
            tabs.append(tab)
            webViews.append(webView)
        }

        for (index, webView) in webViews.enumerated() {
            let loaded = try await waitUntil(timeout: 30) {
                webView.title == "ready-\(index)"
            }
            XCTAssertTrue(loaded, "ballast page \(index) did not finish loading")
        }
        // Let allocations and process bookkeeping settle.
        try await Task.sleep(nanoseconds: 2_000_000_000)

        let ourPIDs = ProcessMeter.webContentPIDs().subtracting(baselinePIDs)
        XCTAssertFalse(ourPIDs.isEmpty, "expected the test's own WebContent process(es)")
        let before = ProcessMeter.footprint(of: ourPIDs)
        XCTAssertGreaterThan(before, 0)

        for tab in tabs {
            await hibernator.hibernate(tab)
            XCTAssertTrue(tab.isHibernated)
            XCTAssertNil(tab.webView, "hibernated tab must hold no WKWebView")
        }
        webViews.removeAll()

        // WebKit tears content processes down asynchronously.
        _ = try await waitUntil(timeout: 20) {
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
