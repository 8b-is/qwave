import Foundation
import MetricKit
import BrowserCore
import QwaveSupport

/// Subscribes to MetricKit and keeps a small, local ring of reliability events
/// (crash / hang / CPU / disk) for the read-only qwave://diagnostics page.
///
/// Privacy-first: everything is stored on this Mac only. There is no telemetry
/// endpoint and no third-party SDK — `submissionEnabled` reflects an opt-in
/// preference for display, but nothing is ever uploaded automatically.
///
/// MetricKit delivers payloads on a background thread, so the subscriber hooks
/// are `nonisolated`: they map the (non-Sendable) payloads into Sendable
/// `DiagnosticRecord`s synchronously, then hop to the main actor to persist.
@MainActor
final class DiagnosticsStore: NSObject {
    private(set) var records: [DiagnosticRecord] = []
    let submissionEnabled: Bool

    private let fileURL: URL
    private let maxRecords = 100

    override init() {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("Qwave", isDirectory: true)
        fileURL = directory.appendingPathComponent("diagnostics.json")
        // Opt-in submission defaults OFF; there is no auto phone-home path.
        submissionEnabled = UserDefaults.standard.bool(forKey: "diagnosticsSubmissionEnabled")
        super.init()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
        MXMetricManager.shared.add(self)
        QwaveLog.browser.info("MetricKit subscribed; \(records.count) diagnostics on record")
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode([DiagnosticRecord].self, from: data)
        else { return }
        records = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    fileprivate func ingest(_ incoming: [DiagnosticRecord]) {
        guard !incoming.isEmpty else { return }
        records = (incoming + records).sorted { $0.date > $1.date }
        if records.count > maxRecords {
            records = Array(records.prefix(maxRecords))
        }
        persist()
        QwaveLog.browser.info("MetricKit diagnostics ingested: \(incoming.count) new, \(records.count) total")
    }
}

extension DiagnosticsStore: MXMetricManagerSubscriber {
    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        // Aggregate metrics are not surfaced on the page (crash/hang/CPU/disk
        // is what reliability triage needs), but subscribing proves the feed.
        QwaveLog.browser.info("MetricKit delivered \(payloads.count) metric payload(s)")
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let mapped = payloads.compactMap(DiagnosticsStore.record(from:))
        guard !mapped.isEmpty else { return }
        Task { @MainActor [weak self] in
            self?.ingest(mapped)
        }
    }

    /// Collapses one MetricKit diagnostic payload into a single record. Uses
    /// only the stable array counts + timestamp + JSON representation so it is
    /// resilient across OS versions.
    private nonisolated static func record(from payload: MXDiagnosticPayload) -> DiagnosticRecord? {
        let crash = payload.crashDiagnostics?.count ?? 0
        let hang = payload.hangDiagnostics?.count ?? 0
        let cpu = payload.cpuExceptionDiagnostics?.count ?? 0
        let disk = payload.diskWriteExceptionDiagnostics?.count ?? 0
        guard
            let kind = DiagnosticRecord.primaryKind(
                crash: crash, hang: hang, cpuException: cpu, diskWriteException: disk),
            let summary = DiagnosticRecord.summarize(
                crash: crash, hang: hang, cpuException: cpu, diskWriteException: disk)
        else { return nil }
        let raw = String(data: payload.jsonRepresentation(), encoding: .utf8) ?? ""
        return DiagnosticRecord(
            kind: kind, date: payload.timeStampEnd, summary: summary, detail: String(raw.prefix(8000)))
    }
}
