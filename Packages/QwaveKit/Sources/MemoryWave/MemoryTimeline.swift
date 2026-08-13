import Foundation

public enum TimelineRange: String, Sendable, Equatable, CaseIterable {
    case today
    case week
    case all

    public func interval(now: Date = Date(), calendar: Calendar = .current) -> (Date?, Date?) {
        switch self {
        case .today:
            return (calendar.startOfDay(for: now), nil)
        case .week:
            let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))
            return (start, nil)
        case .all:
            return (nil, nil)
        }
    }

    public var displayName: String {
        switch self {
        case .today: return "Today"
        case .week: return "This week"
        case .all: return "Everything"
        }
    }
}

public struct TimelineDay: Equatable, Sendable {
    public var day: Date
    public var heading: String
    public var items: [MemoryRecord]

    public init(day: Date, heading: String, items: [MemoryRecord]) {
        self.day = day
        self.heading = heading
        self.items = items
    }
}

public enum MemoryTimeline {
    public static func group(
        _ records: [MemoryRecord],
        calendar: Calendar = .current
    ) -> [TimelineDay] {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .full
        formatter.timeStyle = .none

        var buckets: [Date: [MemoryRecord]] = [:]
        for record in records {
            let day = calendar.startOfDay(for: record.created)
            buckets[day, default: []].append(record)
        }
        return buckets.keys.sorted(by: >).map { day in
            let items = (buckets[day] ?? []).sorted { $0.created > $1.created }
            return TimelineDay(day: day, heading: formatter.string(from: day), items: items)
        }
    }

    /// Titles + times (+ optional snippets). Remote summaries never get bodies.
    public static func summaryCorpus(_ records: [MemoryRecord], includeSnippets: Bool) -> String {
        let time = DateFormatter()
        time.dateStyle = .none
        time.timeStyle = .short
        return records.map { record in
            let host = record.url?.host ?? ""
            let stamp = time.string(from: record.created)
            var line = "- \(stamp) \(record.title)"
            if !host.isEmpty { line += " (\(host))" }
            if includeSnippets {
                let snippet = record.body.replacingOccurrences(of: "\n", with: " ")
                if !snippet.isEmpty {
                    line += ": \(snippet.prefix(160))"
                }
            }
            return line
        }.joined(separator: "\n")
    }
}
