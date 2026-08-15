import Foundation

/// A single locally-captured reliability event surfaced on qwave://diagnostics.
/// Purely a value type so the page renderer and the MetricKit ingest path in
/// the app target can share it; MetricKit itself is never imported here.
public struct DiagnosticRecord: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case crash
        case hang
        case cpuException
        case diskWriteException
        case metrics

        public var label: String {
            switch self {
            case .crash: return "Crash"
            case .hang: return "Hang"
            case .cpuException: return "CPU exception"
            case .diskWriteException: return "Disk write exception"
            case .metrics: return "Metrics"
            }
        }
    }

    public var id: UUID
    public var kind: Kind
    public var date: Date
    public var summary: String
    public var detail: String

    public init(id: UUID = UUID(), kind: Kind, date: Date, summary: String, detail: String = "") {
        self.id = id
        self.kind = kind
        self.date = date
        self.summary = summary
        self.detail = detail
    }

    /// The category shown as the row's headline when a MetricKit diagnostic
    /// payload bundles several kinds together. Crash outranks hang outranks CPU
    /// outranks disk. Pure so it is unit-testable without MetricKit.
    public static func primaryKind(
        crash: Int, hang: Int, cpuException: Int, diskWriteException: Int
    ) -> Kind? {
        if crash > 0 { return .crash }
        if hang > 0 { return .hang }
        if cpuException > 0 { return .cpuException }
        if diskWriteException > 0 { return .diskWriteException }
        return nil
    }

    /// A human count summary such as "2 crashes, 1 hang". Returns nil when the
    /// payload carried nothing worth surfacing.
    public static func summarize(
        crash: Int, hang: Int, cpuException: Int, diskWriteException: Int
    ) -> String? {
        var bits: [String] = []
        if crash > 0 { bits.append("\(crash) crash\(crash == 1 ? "" : "es")") }
        if hang > 0 { bits.append("\(hang) hang\(hang == 1 ? "" : "s")") }
        if cpuException > 0 { bits.append("\(cpuException) CPU exception\(cpuException == 1 ? "" : "s")") }
        if diskWriteException > 0 {
            bits.append("\(diskWriteException) disk write exception\(diskWriteException == 1 ? "" : "s")")
        }
        return bits.isEmpty ? nil : bits.joined(separator: ", ")
    }
}
