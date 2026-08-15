import XCTest
@testable import BrowserCore

final class DiagnosticsPageTests: XCTestCase {
    func testEmptyStateRenders() {
        let html = InternalPages.diagnosticsHTML(records: [], submissionEnabled: false)
        XCTAssertTrue(html.contains("Diagnostics"))
        XCTAssertTrue(html.contains("No diagnostics captured yet"))
        XCTAssertTrue(html.contains("Local only. Qwave never sends diagnostics off this Mac."))
        XCTAssertTrue(html.contains("qwave://start"))
        // Read-only: no message-handler wiring.
        XCTAssertFalse(html.contains("messageHandlers.qwave"))
    }

    func testRecordsRender() {
        let html = InternalPages.diagnosticsHTML(
            records: [
                DiagnosticRecord(
                    kind: .crash,
                    date: Date(timeIntervalSince1970: 0),
                    summary: "1 crash",
                    detail: "{\"foo\":\"bar\"}"),
                DiagnosticRecord(
                    kind: .hang,
                    date: Date(timeIntervalSince1970: 0),
                    summary: "2 hangs",
                    detail: ""),
            ],
            submissionEnabled: false)
        XCTAssertTrue(html.contains("Crash"))
        XCTAssertTrue(html.contains("1 crash"))
        XCTAssertTrue(html.contains("Hang"))
        XCTAssertTrue(html.contains("2 hangs"))
        XCTAssertTrue(html.contains("diag-raw"))
        // Raw JSON is escaped into the page.
        XCTAssertTrue(html.contains("&quot;foo&quot;"))
    }

    func testSubmissionOptInReflectedButNeverUploads() {
        let on = InternalPages.diagnosticsHTML(records: [], submissionEnabled: true)
        XCTAssertTrue(on.contains("no telemetry endpoint"))
    }

    func testIsDiagnosticsURL() {
        XCTAssertTrue(InternalPages.isDiagnosticsURL(URL(string: "qwave://diagnostics")))
        XCTAssertFalse(InternalPages.isDiagnosticsURL(URL(string: "qwave://start")))
        XCTAssertFalse(InternalPages.isDiagnosticsURL(URL(string: "https://example.com")))
    }
}

final class DiagnosticRecordTests: XCTestCase {
    func testSummarizePluralization() {
        XCTAssertEqual(
            DiagnosticRecord.summarize(crash: 1, hang: 0, cpuException: 0, diskWriteException: 0),
            "1 crash")
        XCTAssertEqual(
            DiagnosticRecord.summarize(crash: 2, hang: 3, cpuException: 0, diskWriteException: 0),
            "2 crashes, 3 hangs")
        XCTAssertEqual(
            DiagnosticRecord.summarize(crash: 0, hang: 0, cpuException: 1, diskWriteException: 4),
            "1 CPU exception, 4 disk write exceptions")
        XCTAssertNil(
            DiagnosticRecord.summarize(crash: 0, hang: 0, cpuException: 0, diskWriteException: 0))
    }

    func testPrimaryKindPrecedence() {
        XCTAssertEqual(
            DiagnosticRecord.primaryKind(crash: 1, hang: 9, cpuException: 9, diskWriteException: 9),
            .crash)
        XCTAssertEqual(
            DiagnosticRecord.primaryKind(crash: 0, hang: 1, cpuException: 9, diskWriteException: 9),
            .hang)
        XCTAssertEqual(
            DiagnosticRecord.primaryKind(crash: 0, hang: 0, cpuException: 0, diskWriteException: 2),
            .diskWriteException)
        XCTAssertNil(
            DiagnosticRecord.primaryKind(crash: 0, hang: 0, cpuException: 0, diskWriteException: 0))
    }

    func testCodableRoundTrip() throws {
        let record = DiagnosticRecord(
            kind: .cpuException, date: Date(timeIntervalSince1970: 100), summary: "1 CPU exception", detail: "raw")
        let data = try JSONEncoder().encode([record])
        let decoded = try JSONDecoder().decode([DiagnosticRecord].self, from: data)
        XCTAssertEqual(decoded, [record])
    }
}
