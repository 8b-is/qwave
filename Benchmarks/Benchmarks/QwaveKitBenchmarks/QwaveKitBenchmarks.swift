import Benchmark
import Foundation
import BrowserCore
import Persistence
import Shields

/// In-process benchmarks. Thresholds check `mallocCountTotal` — allocation
/// counts are deterministic for a given code path, so they survive noisy or
/// heterogeneous runners where wall-clock cannot. Wall-clock is collected
/// for local reading but never checked in CI.
///
/// These do NOT cover the hibernation memory claim: that memory lives in
/// WebKit's out-of-process content processes and is measured by
/// `BrowserCoreTests/HibernationReclaimTests`.
let benchmarks: @Sendable () -> Void = {
    // mallocCountTotal only: allocation counts are near-deterministic for a
    // given code path, so they survive heterogeneous runners; wall-clock
    // does not and is never CI-checked. 25% p90 tolerance absorbs
    // allocator/toolchain drift while a real regression (2x allocations)
    // still fails.
    // retainCount/releaseCount/retainReleaseDelta are similarly deterministic
    // and capture ARC traffic that mallocCountTotal misses (e.g. @inlinable
    // effects on dispatch and specialization).
    let checkedMetrics: [BenchmarkMetric] = [
        .mallocCountTotal,
        .retainCount,
        .releaseCount,
        .retainReleaseDelta,
    ]
    let tolerance: [BenchmarkMetric: BenchmarkThresholds] = [
        .mallocCountTotal: .init(relative: [.p90: 25.0]),
        .retainCount: .init(relative: [.p90: 5.0]),
        .releaseCount: .init(relative: [.p90: 5.0]),
        .retainReleaseDelta: .init(relative: [.p90: 5.0]),
    ]

    // Every keystroke runs this — and since v0.3.0 it goes through the
    // WHATWG parser, so this is where the WebURL adoption is measured
    // rather than asserted.
    Benchmark(
        "OmniboxParser.parse",
        configuration: .init(metrics: checkedMetrics, scalingFactor: .kilo, thresholds: tolerance)
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(OmniboxParser.parse("example.com/path?q=1"))
            blackHole(OmniboxParser.parse("how do wave functions collapse"))
            blackHole(OmniboxParser.parse("https://sub.example.co.uk:8443/a?b=c#d"))
        }
    }

    // History-backed suggestions rank on every keystroke too.
    Benchmark(
        "OmniboxSuggester.suggestions(500 entries)",
        configuration: .init(metrics: checkedMetrics, scalingFactor: .kilo, thresholds: tolerance)
    ) { benchmark in
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let history = (0..<500).map { index in
            HistoryEntry(
                id: Int64(index),
                url: URL(string: "https://site\(index % 97).example/page/\(index)")!,
                title: "Page \(index) about topic \(index % 13)",
                visitCount: index % 40 + 1,
                lastVisit: now.addingTimeInterval(-Double(index) * 3600),
                containerID: nil
            )
        }
        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            blackHole(OmniboxSuggester.suggestions(for: "site", history: history, now: now))
        }
    }

    // Realistic-scale history queries (50k rows, SQLite WAL on disk).
    Benchmark(
        "HistoryStore.entries(matching:) @ 50k rows",
        configuration: .init(metrics: checkedMetrics, maxDuration: .seconds(20), thresholds: tolerance)
    ) { benchmark in
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwave-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let database = try SQLiteDatabase(url: dir.appendingPathComponent("bench.db"))
        let store = try HistoryStore(database: database)
        for index in 0..<50_000 {
            try store.recordVisit(
                url: URL(string: "https://host\(index % 1_000).example/p/\(index)")!,
                title: "Title \(index) keyword\(index % 500)",
                containerID: nil,
                at: Date(timeIntervalSince1970: 1_700_000_000 - Double(index))
            )
        }
        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            blackHole(try store.entries(matching: "keyword42", limit: 50))
        }
    }

    // The uBO → WebKit JSON compiler (the pure half of the blocklist
    // pipeline; the WKContentRuleListStore half is budgeted in
    // ShieldsTests/BlocklistPerformanceTests).
    Benchmark(
        "UBORuleListCompiler.compileJSON(1k rules)",
        configuration: .init(metrics: checkedMetrics, maxDuration: .seconds(20), thresholds: tolerance)
    ) { benchmark in
        let lines = (0..<1_000).map { index -> String in
            switch index % 4 {
            case 0: return "||ads\(index).example.com^"
            case 1: return "||tracker\(index).example.com^$third-party"
            case 2: return "||cdn\(index).example.com/banner^$image,script"
            default: return "@@||allowed\(index).example.com^"
            }
        }.joined(separator: "\n")
        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            blackHole(UBORuleListCompiler.compileJSON(from: lines))
        }
    }

    // Session snapshot round-trip (launch/quit path). TabManager is
    // MainActor-isolated; the benchmark hops once per iteration set.
    Benchmark(
        "SessionRestorer round-trip (40 tabs)",
        configuration: .init(metrics: checkedMetrics, maxDuration: .seconds(20), thresholds: tolerance)
    ) { benchmark in
        await MainActor.run {
            let manager = TabManager()
            for index in 0..<40 {
                let tab = Tab(pendingURL: URL(string: "https://site\(index).example/"))
                tab.isPinned = index < 3
                manager.append(tab, select: false)
            }
            benchmark.startMeasurement()
            for _ in benchmark.scaledIterations {
                let snapshot = SessionRestorer.snapshot(of: [manager])
                blackHole(SessionRestorer.managers(from: snapshot))
            }
        }
    }
}
