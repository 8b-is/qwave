import XCTest
import WebKit
@testable import Shields

/// The blocklist performance budget (docs/ENERGY.md). The v0.3.0 list grew
/// 51 → 59,657 rules; these tests keep its cost measured and bounded instead
/// of asserted. Budgets are ~2× the numbers measured on an M-class laptop so
/// slower CI runners pass while a pathological regression (rule explosion,
/// cache defeat, main-thread compile) still fails.
final class UnsafeSendableBox<T>: @unchecked Sendable {
    var value: T?
}

@MainActor
final class BlocklistPerformanceTests: XCTestCase {
    /// Budgets. Measured 2026-08-13 (see docs/ENERGY.md for the method and
    /// the measured numbers behind these ceilings).
    private static let coldCompileBudget: TimeInterval = 15
    private static let warmLoadBudget: TimeInterval = 2
    private static let mainThreadStallBudget: TimeInterval = 0.5

    private func freshStoreDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwave-blocklist-perf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func directorySize(_ dir: URL) -> Int {
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey], options: []
            )) ?? []
        return files.reduce(0) { total, file in
            total + ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    func testColdCompileWarmLoadAndArtifactSizeWithinBudget() async throws {
        let dir = try freshStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Cold: nothing in the store — the full 59k-rule compile runs.
        let coldStore = WKContentRuleListStore(url: dir)!
        let coldCompiler = RuleListCompiler(store: coldStore)
        let coldStart = ContinuousClock.now
        _ = try await coldCompiler.compiledList(for: .adsAndTrackers)
        let cold = ContinuousClock.now - coldStart
        let coldSeconds =
            Double(cold.components.seconds)
            + Double(cold.components.attoseconds) / 1e18

        let artifactBytes = directorySize(dir)

        // Warm: fresh compiler AND fresh store object on the same directory —
        // simulates a relaunch. The content-hash identifier must hit the
        // on-disk cache, not recompile.
        let warmStore = WKContentRuleListStore(url: dir)!
        let warmCompiler = RuleListCompiler(store: warmStore)
        let warmStart = ContinuousClock.now
        _ = try await warmCompiler.compiledList(for: .adsAndTrackers)
        let warm = ContinuousClock.now - warmStart
        let warmSeconds =
            Double(warm.components.seconds)
            + Double(warm.components.attoseconds) / 1e18

        print(
            "[blocklist-budget] cold=\(String(format: "%.2f", coldSeconds))s warm=\(String(format: "%.3f", warmSeconds))s artifact=\(artifactBytes / 1024)KB"
        )

        XCTAssertLessThan(coldSeconds, Self.coldCompileBudget, "cold compile blew the budget")
        XCTAssertLessThan(warmSeconds, Self.warmLoadBudget, "warm load must be cache-hit fast")
        XCTAssertLessThan(warmSeconds, coldSeconds / 2, "warm load not meaningfully faster than cold — cache defeated?")
        XCTAssertGreaterThan(artifactBytes, 0, "compiled artifact should persist on disk")
        XCTAssertLessThan(artifactBytes, 200 * 1024 * 1024, "compiled artifact size out of hand")
    }

    /// A list-content update must not hold the launch path hostage: with a
    /// previous version compiled in the store, `availableList` returns that
    /// stale list immediately and delivers the fresh compile via callback.
    func testStaleListServedWhileFreshCompiles() async throws {
        let dir = try freshStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WKContentRuleListStore(url: dir)!

        // Seed a "previous version": same list prefix, different content hash.
        let staleJSON = #"[{"trigger":{"url-filter":"stale-marker"},"action":{"type":"block"}}]"#
        let staleID = "easylist-compiled-\(RuleListCompiler.stableHash(of: staleJSON))"
        _ = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<WKContentRuleList, Error>) in
            store.compileContentRuleList(forIdentifier: staleID, encodedContentRuleList: staleJSON) { list, error in
                if let list { cont.resume(returning: list) } else { cont.resume(throwing: error!) }
            }
        }

        let compiler = RuleListCompiler(store: store)
        let refreshed = expectation(description: "fresh list delivered")
        let refreshedID = UnsafeSendableBox<String>()

        let start = ContinuousClock.now
        let served = try await compiler.availableList(for: .adsAndTrackers) { fresh in
            refreshedID.value = fresh.identifier
            refreshed.fulfill()
        }
        let elapsed = ContinuousClock.now - start
        let servedSeconds =
            Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18

        XCTAssertEqual(served.identifier, staleID, "the previous version must be served immediately")
        XCTAssertLessThan(servedSeconds, Self.warmLoadBudget, "stale path must be cache-hit fast, not compile-slow")

        await fulfillment(of: [refreshed], timeout: Self.coldCompileBudget)
        XCTAssertNotEqual(refreshedID.value, staleID)
        XCTAssertEqual(refreshedID.value?.hasPrefix("easylist-compiled-"), true)

        // The superseded artifact is removed so the store doesn't grow
        // version over version.
        let remaining = await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            store.getAvailableContentRuleListIdentifiers { cont.resume(returning: $0 ?? []) }
        }
        XCTAssertFalse(remaining.contains(staleID))
    }

    /// Regression guard: compiling the 59k-rule list must not stall the main
    /// thread. A 50ms heartbeat runs on the main queue during the compile;
    /// if any beat-to-beat gap exceeds the stall budget, compilation moved
    /// onto the main thread and the test fails.
    func testCompileDoesNotStallMainThread() async throws {
        let dir = try freshStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let compiler = RuleListCompiler(store: WKContentRuleListStore(url: dir)!)

        final class Beats: @unchecked Sendable {
            var maxGap: TimeInterval = 0
            var last = Date()
        }
        let beats = Beats()
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            let now = Date()
            beats.maxGap = max(beats.maxGap, now.timeIntervalSince(beats.last))
            beats.last = now
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }

        beats.last = Date()
        _ = try await compiler.compiledList(for: .adsAndTrackers)

        print("[blocklist-budget] max main-thread stall during compile: \(Int(beats.maxGap * 1000))ms")
        XCTAssertLessThan(
            beats.maxGap, Self.mainThreadStallBudget,
            "main thread stalled \(Int(beats.maxGap * 1000))ms during rule compile"
        )
    }
}
