import Foundation
import WhoopStore

/// Browsing the scores the Mac sent back (#80). Pure date and summary logic for the phone's week strip and History
/// screen, kept here so it can be tested.
///
/// Days are the Mac's local calendar days ("YYYY-MM-DD"), used as labels: the phone never re-buckets them by its own
/// time zone, so travel or a DST change cannot move a score to another day. Calendar arithmetic is done on noon of
/// each day, so a 23- or 25-hour day can never skip or repeat a date.
public enum ScoreHistory {
    static func formatter(_ calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = calendar; f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f
    }

    /// Noon of `day` in `calendar`'s zone (nil for a malformed day).
    public static func noon(_ day: String, calendar: Calendar = .current) -> Date? {
        formatter(calendar).date(from: day).flatMap { calendar.date(bySettingHour: 12, minute: 0, second: 0, of: $0) }
    }

    public static func day(_ date: Date, calendar: Calendar = .current) -> String { formatter(calendar).string(from: date) }

    /// `day` moved by `delta` calendar days.
    public static func shift(_ day: String, by delta: Int, calendar: Calendar = .current) -> String? {
        noon(day, calendar: calendar).flatMap { calendar.date(byAdding: .day, value: delta, to: $0) }.map { Self.day($0, calendar: calendar) }
    }

    /// The seven days (Monday first) of the week containing `day`.
    public static func week(containing day: String, calendar: Calendar = .current) -> [String] {
        var cal = calendar; cal.firstWeekday = 2
        guard let d = noon(day, calendar: cal), let start = cal.dateInterval(of: .weekOfYear, for: d)?.start,
              let startNoon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: start) else { return [] }
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: startNoon) }.map { Self.day($0, calendar: cal) }
    }

    /// The days from `count - 1` days before `through` up to `through`, oldest first.
    public static func lastDays(_ count: Int, through: String, calendar: Calendar = .current) -> [String] {
        (0..<max(0, count)).reversed().compactMap { shift(through, by: -$0, calendar: calendar) }
    }

    /// Summaries grouped by month ("YYYY-MM"), newest month and newest day first. Removed days are dropped.
    public static func months(_ summaries: [DailySummary]) -> [(month: String, days: [DailySummary])] {
        let kept = summaries.filter { !$0.removed }.sorted { $0.day > $1.day }
        var out: [(month: String, days: [DailySummary])] = []
        for s in kept {
            let m = String(s.day.prefix(7))
            if out.last?.month == m { out[out.count - 1].days.append(s) } else { out.append((m, [s])) }
        }
        return out
    }

    /// One value per day of `days` (nil where that day has no summary or no such value: missing is never 0).
    public static func series(_ key: String, days: [String], in summaries: [DailySummary]) -> [Double?] {
        let byDay = Dictionary(summaries.filter { !$0.removed }.map { ($0.day, $0) }, uniquingKeysWith: { a, b in
            a.revision >= b.revision ? a : b
        })
        return days.map { byDay[$0]?.values[key] }
    }

    public struct Average: Equatable, Sendable {
        public let value: Double
        /// Days that had a value, out of the days asked about.
        public let daysWithValue: Int
        public let daysAsked: Int
    }

    /// Mean over the days that have a value; nil when none do.
    public static func average(_ values: [Double?]) -> Average? {
        let present = values.compactMap { $0 }
        guard !present.isEmpty else { return nil }
        return Average(value: present.reduce(0, +) / Double(present.count), daysWithValue: present.count,
                       daysAsked: values.count)
    }
}
