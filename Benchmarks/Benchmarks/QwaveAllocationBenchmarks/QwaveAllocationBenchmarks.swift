import Benchmark
import Foundation
import BrowserCore

/// Second benchmark target: allocation measurement for hot paths that the
/// original suite does not cover, plus a re-verification of the
/// `SessionRestorer` round-trip claim.
///
/// These are the pure in-process halves:
/// - `MarkdownCompiler.compile` — runs on every internal doc page load
///   (start page chips, docs, timeline). The shipped docs pages carry code
///   fences, tables, math and mermaid blocks, so the sample mirrors that mix.
/// - `InternalPages.startHTML` — the start page shell, generated per launch.
/// - `SessionRestorer` 40-tab round-trip — an exact mirror of the original
///   suite's setup, re-measured because the committed threshold (65 mallocs
///   for encode+decode of 40 tabs) is implausibly low and predates any
///   documented measurement.
///
/// Thresholds live in `Benchmarks/Thresholds/` and are CI-checked the same
/// way as the first target. `FaviconLoader` is intentionally absent: it is
/// app-target code (decodes `NSImage` from fetched data) and out of scope
/// for the package benchmark runner.
let benchmarks: @Sendable () -> Void = {
    let checkedMetrics: [BenchmarkMetric] = [.mallocCountTotal]
    let tolerance: [BenchmarkMetric: BenchmarkThresholds] = [
        .mallocCountTotal: .init(relative: [.p90: 25.0])
    ]

    // A representative internal doc page: headings, emphasis, links, lists,
    // a table, a code fence, math, and a mermaid block — the mix Qwave's own
    // markdown pages actually ship (KaTeX/mermaid are client-side, but the
    // compiler still walks every fenced block and table row).
    let docMarkdown = """
        # Module Boundaries

        ## Why six packages?

        The split is deliberate: build times, testability, and the
        `QwaveTunnelKit` boundary. Each package is a *reviewable* unit.

        - **BrowserCore** — tabs, hibernation, session restore.
        - **Persistence** — SQLite-backed history and bookmarks.
        - **Shields** — rule compile and the HTTPS-First upgrader.

        | Module | Role | Alloc profile |
        |---|---|---|
        | BrowserCore | tabs, hibernation | measured |
        | Persistence | history at 50k rows | gated |
        | Shields | rule compile | budgeted |

        ```swift
        let tab = Tab(pendingURL: url)
        tab.isPinned = index < 3
        manager.append(tab, select: false)
        ```

        $$
        E = mc^2
        $$

        ```mermaid
        graph TD
          A[WebContent] --> B[GPU process]
          B --> C[Metal]
        ```
        """

    Benchmark(
        "MarkdownCompiler.compile_(internal_doc_page)",
        configuration: .init(metrics: checkedMetrics, scalingFactor: .kilo, thresholds: tolerance)
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(MarkdownCompiler.compile(docMarkdown, trust: .rawHTMLAllowed))
        }
    }

    let startMemories = (0..<8).map { index in
        StartMemoryChip(title: "Memory #\(index)", preview: "Preview text \(index) — #tag")
    }

    Benchmark(
        "InternalPages.startHTML_(8_memories)",
        configuration: .init(metrics: checkedMetrics, scalingFactor: .kilo, thresholds: tolerance)
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(InternalPages.startHTML(memories: startMemories, providerLabel: "On-device"))
        }
    }

    // Exact mirror of QwaveKitBenchmarks' SessionRestorer setup so the
    // numbers are comparable to the committed 65-malloc threshold.
    Benchmark(
        "SessionRestorer_round-trip_(40_tabs,_re-verify)",
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
