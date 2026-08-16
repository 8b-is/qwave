import Foundation
import MCP
import Persistence
import XCTest

@testable import MCPSurface

/// Every test here runs against a REAL profile directory on disk — a real
/// `browser.db` written through the same `HistoryStore`/`BookmarkStore` actors
/// the browser writes through, and a real `session.json` written through
/// `SessionStore`. Nothing is mocked, and every assertion names a seeded value,
/// so a handler that silently returned nothing would fail rather than pass.
final class QwaveMCPServiceTests: XCTestCase {
    private var profile: QwaveProfileLocation!

    override func setUp() async throws {
        try await super.setUp()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwave-mcp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        profile = QwaveProfileLocation(directory: directory)
    }

    override func tearDown() async throws {
        if let profile { try? FileManager.default.removeItem(at: profile.directory) }
        profile = nil
        try await super.tearDown()
    }

    // MARK: - Seeding

    // Hosts nothing else in the process could produce, and — deliberately —
    // containing no `/`, so a containment assertion is not silently defeated
    // by JSON escaping (`https:\/\/…`). That is a real trap: the first cut of
    // these tests asserted on full URLs and could never have failed.
    private static let historyMarker = "leak-history-marker.example"
    private static let bookmarkMarker = "leak-bookmark-marker.example"
    private static let tabMarker = "leak-tab-marker.example"
    private static let titleMarker = "LEAKTITLE"

    private static let seededHistoryURL = "https://\(historyMarker)/blog/"
    private static let seededHistoryTitle = "Surfin Safari \(titleMarker)"
    private static let seededBookmarkURL = "https://\(bookmarkMarker)/documentation/"
    private static let seededTabURL = "https://\(tabMarker)/"

    private func seedDatabase() async throws {
        let database = try SQLiteDatabase(url: profile.browserDatabase)
        let history = try await HistoryStore(database: database)
        try await history.recordVisit(
            url: URL(string: Self.seededHistoryURL)!, title: Self.seededHistoryTitle,
            containerID: nil, at: Date(timeIntervalSince1970: 1_700_000_000))
        try await history.recordVisit(
            url: URL(string: Self.seededHistoryURL)!, title: Self.seededHistoryTitle,
            containerID: nil, at: Date(timeIntervalSince1970: 1_700_000_100))
        try await history.recordVisit(
            url: URL(string: "https://example.com/unrelated")!, title: "Unrelated",
            containerID: nil, at: Date(timeIntervalSince1970: 1_700_000_200))

        let bookmarks = try await BookmarkStore(database: database)
        try await bookmarks.add(
            title: "Swift Docs", url: URL(string: Self.seededBookmarkURL)!, folder: "Dev",
            at: Date(timeIntervalSince1970: 1_700_000_300))
    }

    private func seedSession(savedAt: Date = Date(timeIntervalSince1970: 1_700_000_400)) async throws {
        let store = try await SessionStore(directory: profile.directory)
        try await store.save(
            SessionSnapshot(
                windows: [
                    WindowSnapshot(
                        tabs: [
                            TabSnapshot(
                                url: URL(string: Self.seededTabURL)!, title: "8b.is",
                                containerID: UUID(), isPinned: true,
                                // Stands in for WebKit interaction state: back/forward
                                // list, scroll offsets and form field contents.
                                interactionState: Data("SECRET-FORM-STATE".utf8)),
                            TabSnapshot(
                                url: URL(string: "https://webkit.org/")!, title: "WebKit",
                                containerID: nil, isPinned: false),
                        ],
                        selectedIndex: 1)
                ],
                savedAt: savedAt))
    }

    private func service(enabled: Bool, now: @escaping @Sendable () -> Date = Date.init) -> QwaveMCPService {
        QwaveMCPService(
            gate: .fixed(enabled),
            reader: BrowserSnapshotReader(location: profile, now: now))
    }

    private func text(_ result: CallTool.Result) -> String {
        result.content.compactMap { content -> String? in
            if case .text(let text, _, _) = content { return text }
            return nil
        }.joined(separator: "\n")
    }

    private func decode<T: Decodable>(_ type: T.Type, from result: CallTool.Result) throws -> T {
        XCTAssertNotEqual(result.isError, true, "tool returned an error: \(text(result))")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(text(result).utf8))
    }

    // MARK: - The default-OFF guarantee
    //
    // This is the test that must fail if the gate is removed. It seeds a real
    // history row and then asserts BOTH that the call is refused AND that the
    // seeded URL appears nowhere in the response. Deleting the `guard
    // gate.isEnabled` in QwaveMCPService.callTool makes the handler run against
    // the seeded store, the URL appears, and this fails.

    func testGateOffRefusesEveryToolAndLeaksNoSeededData() async throws {
        try await seedDatabase()
        try await seedSession()
        let service = service(enabled: false)

        for tool in [
            QwaveMCPTools.searchHistoryName,
            QwaveMCPTools.recentHistoryName,
            QwaveMCPTools.listBookmarksName,
            QwaveMCPTools.lastSavedSessionName,
        ] {
            let result = await service.callTool(
                name: tool, arguments: ["query": .string(Self.historyMarker)])
            XCTAssertEqual(result.isError, true, "\(tool) answered while the gate was shut")
            let body = text(result)
            XCTAssertFalse(body.contains(Self.historyMarker), "\(tool) leaked history")
            XCTAssertFalse(body.contains(Self.titleMarker), "\(tool) leaked a page title")
            XCTAssertFalse(body.contains(Self.bookmarkMarker), "\(tool) leaked a bookmark")
            XCTAssertFalse(body.contains(Self.tabMarker), "\(tool) leaked a saved tab")
        }
    }

    /// The other half of the guarantee, and the thing that keeps the test above
    /// honest: with the gate ON, those exact markers DO appear. Without this,
    /// the gate-off test would also pass against handlers that are simply
    /// broken — or against a payload encoding that hid the markers.
    func testGateOnReturnsEveryMarkerTheGateOffTestProvedWasWithheld() async throws {
        try await seedDatabase()
        try await seedSession()
        let service = service(enabled: true)

        let history = await service.callTool(
            name: QwaveMCPTools.searchHistoryName, arguments: ["query": .string(Self.historyMarker)])
        XCTAssertTrue(text(history).contains(Self.historyMarker))
        XCTAssertTrue(text(history).contains(Self.titleMarker))
        XCTAssertTrue(text(history).contains(Self.seededHistoryURL), "slashes must not be escaped")

        let bookmarks = await service.callTool(name: QwaveMCPTools.listBookmarksName, arguments: nil)
        XCTAssertTrue(text(bookmarks).contains(Self.bookmarkMarker))

        let session = await service.callTool(name: QwaveMCPTools.lastSavedSessionName, arguments: nil)
        XCTAssertTrue(text(session).contains(Self.tabMarker))
    }

    func testGateOffAdvertisesNoTools() async {
        let tools = await service(enabled: false).listTools()
        XCTAssertTrue(tools.isEmpty)
    }

    func testGateOnAdvertisesTheFullCatalogueAsReadOnly() async {
        let tools = await service(enabled: true).listTools()
        XCTAssertEqual(tools.count, 4)
        XCTAssertEqual(
            Set(tools.map(\.name)),
            [
                QwaveMCPTools.searchHistoryName, QwaveMCPTools.recentHistoryName,
                QwaveMCPTools.listBookmarksName, QwaveMCPTools.lastSavedSessionName,
            ])
        for tool in tools {
            XCTAssertEqual(tool.annotations.readOnlyHint, true, "\(tool.name) is not marked read-only")
            XCTAssertEqual(tool.annotations.openWorldHint, false, "\(tool.name) claims an open world")
        }
    }

    // MARK: - History

    func testSearchHistoryMatchesTitleAndURLAndExcludesNonMatches() async throws {
        try await seedDatabase()
        let service = service(enabled: true)

        let byURL = try decode(
            [HistoryItem].self,
            from: await service.callTool(
                name: QwaveMCPTools.searchHistoryName, arguments: ["query": .string(Self.historyMarker)]))
        XCTAssertEqual(byURL.map(\.url), [Self.seededHistoryURL])
        XCTAssertEqual(byURL.first?.visitCount, 2)
        XCTAssertEqual(byURL.first?.title, Self.seededHistoryTitle)
        XCTAssertEqual(byURL.first?.lastVisit, Date(timeIntervalSince1970: 1_700_000_100))

        let byTitle = try decode(
            [HistoryItem].self,
            from: await service.callTool(
                name: QwaveMCPTools.searchHistoryName, arguments: ["query": .string(Self.titleMarker)]))
        XCTAssertEqual(byTitle.map(\.url), [Self.seededHistoryURL])

        let miss = try decode(
            [HistoryItem].self,
            from: await service.callTool(
                name: QwaveMCPTools.searchHistoryName,
                arguments: ["query": .string("no-such-string-anywhere")]))
        XCTAssertTrue(miss.isEmpty)
    }

    func testRecentHistoryIsNewestFirst() async throws {
        try await seedDatabase()
        let rows = try decode(
            [HistoryItem].self,
            from: await service(enabled: true).callTool(
                name: QwaveMCPTools.recentHistoryName, arguments: nil))
        XCTAssertEqual(rows.map(\.url), ["https://example.com/unrelated", Self.seededHistoryURL])
    }

    func testLimitIsClampedRatherThanHonoured() async throws {
        try await seedDatabase()
        let rows = try decode(
            [HistoryItem].self,
            from: await service(enabled: true).callTool(
                name: QwaveMCPTools.recentHistoryName, arguments: ["limit": .int(1)]))
        XCTAssertEqual(rows.count, 1)

        XCTAssertEqual(QwaveMCPTools.resolvedLimit(from: ["limit": .int(1_000_000)]), QwaveMCPTools.maximumLimit)
        XCTAssertEqual(QwaveMCPTools.resolvedLimit(from: ["limit": .int(0)]), 1)
        XCTAssertEqual(QwaveMCPTools.resolvedLimit(from: ["limit": .string("many")]), QwaveMCPTools.defaultLimit)
        XCTAssertEqual(QwaveMCPTools.resolvedLimit(from: nil), QwaveMCPTools.defaultLimit)
    }

    func testSearchHistoryRejectsAMissingQuery() async throws {
        try await seedDatabase()
        let result = await service(enabled: true).callTool(
            name: QwaveMCPTools.searchHistoryName, arguments: nil)
        XCTAssertEqual(result.isError, true)
    }

    // MARK: - Bookmarks

    func testListBookmarksReturnsTheSeededBookmark() async throws {
        try await seedDatabase()
        let rows = try decode(
            [BookmarkItem].self,
            from: await service(enabled: true).callTool(
                name: QwaveMCPTools.listBookmarksName, arguments: nil))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.url, Self.seededBookmarkURL)
        XCTAssertEqual(rows.first?.folder, "Dev")
    }

    // MARK: - Saved session

    func testLastSavedSessionReportsAgeAndCaveatsAndNeverTheInteractionState() async throws {
        try await seedSession(savedAt: Date(timeIntervalSince1970: 1_700_000_400))
        let result = await service(enabled: true, now: { Date(timeIntervalSince1970: 1_700_000_460) })
            .callTool(name: QwaveMCPTools.lastSavedSessionName, arguments: nil)

        let report = try decode(SavedSessionReport.self, from: result)
        XCTAssertEqual(report.savedAt, Date(timeIntervalSince1970: 1_700_000_400))
        XCTAssertEqual(report.ageSeconds, 60)
        XCTAssertEqual(report.windows.count, 1)
        XCTAssertEqual(report.windows[0].selectedIndex, 1)
        XCTAssertEqual(report.windows[0].tabs.map(\.url), [Self.seededTabURL, "https://webkit.org/"])
        XCTAssertEqual(report.windows[0].tabs[0].isPinned, true)
        XCTAssertFalse(report.caveats.isEmpty)

        // The raw payload must not carry WebKit interaction state (form data,
        // full back/forward list) or the container UUID, in any encoding.
        let body = text(result)
        XCTAssertFalse(body.contains("SECRET-FORM-STATE"))
        XCTAssertFalse(body.contains(Data("SECRET-FORM-STATE".utf8).base64EncodedString()))
        XCTAssertFalse(body.lowercased().contains("interactionstate"))
        XCTAssertFalse(body.lowercased().contains("containerid"))
    }

    // MARK: - Missing profile

    /// Opening `browser.db` would CREATE it (SQLITE_OPEN_CREATE), which would
    /// turn "there is no profile" into "the profile is empty". Assert both the
    /// error and that nothing was minted on disk.
    func testMissingDatabaseIsReportedAndNotCreated() async throws {
        let result = await service(enabled: true).callTool(
            name: QwaveMCPTools.recentHistoryName, arguments: nil)
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(text(result).contains("No Qwave profile database"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.browserDatabase.path))
    }

    func testMissingSessionSnapshotIsReported() async {
        let result = await service(enabled: true).callTool(
            name: QwaveMCPTools.lastSavedSessionName, arguments: nil)
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(text(result).contains("never autosaved"))
    }

    func testUnknownToolIsRejected() async {
        let result = await service(enabled: true).callTool(name: "qwave_navigate", arguments: nil)
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(text(result).contains("Unknown tool"))
    }
}
