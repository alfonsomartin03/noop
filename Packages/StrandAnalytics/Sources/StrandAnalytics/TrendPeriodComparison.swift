import Foundation

// TrendPeriodComparison.swift — the selected Trends window against the window just before it, and Z1–Z5 time totals.
// Display helpers only: nothing here feeds a score.
//
// Comparison rule (recorded for issue #4):
// - Periods are trailing whole days of equal length. The current period ends at the latest stored day; when that day is
//   today it is still in progress, so the current period ends YESTERDAY instead (a partly completed day never counts).
//   The previous period is the same number of days immediately before the current one.
// - Each side is the mean of the days that have a value. Missing days are missing, never zero.
// - Each side needs at least `minDays` days with a value (default: half the period, at least 2), else "insufficient".
// - A difference smaller than the metric's `tolerance` (in its own unit) is "unchanged".
// - Direction is only up / down / unchanged. Whether up is good depends on the metric and the person; this type never
//   says "better" or "worse".

public struct TrendPeriodComparison: Equatable, Sendable {
    public enum Direction: String, Equatable, Sendable { case up, down, unchanged, insufficient }

    /// First and last day (inclusive) of each period, as the day-start dates the points use.
    public let currentStart: Date
    public let currentEnd: Date
    public let previousStart: Date
    public let previousEnd: Date
    public let days: Int
    public let currentMean: Double?
    public let previousMean: Double?
    public let currentCount: Int
    public let previousCount: Int
    public let direction: Direction

    /// current − previous, when both sides qualify.
    public var delta: Double? {
        guard direction != .insufficient, let c = currentMean, let p = previousMean else { return nil }
        return c - p
    }

    static let day: TimeInterval = 86_400

    /// - Parameters:
    ///   - points: daily values (any order); `date` is the day's start, as Trends stores it.
    ///   - days: period length; must be ≥ 1 (an "all history" window has no comparison: pass nothing).
    ///   - latest: the latest stored day.
    ///   - today: the current day's start in the same convention; nil = unknown (latest is taken as complete).
    ///   - tolerance: smallest difference, in the metric's unit, that counts as a change.
    public static func compare(_ points: [(date: Date, value: Double)], days n: Int, latest: Date, today: Date?,
                               tolerance: Double, minDays: Int? = nil) -> TrendPeriodComparison? {
        guard n >= 1 else { return nil }
        // Whole days only: an in-progress today is left out.
        let end = today.map { latest >= $0 ? $0.addingTimeInterval(-day) : latest } ?? latest
        let curStart = end.addingTimeInterval(-Double(n - 1) * day)
        let prevEnd = curStart.addingTimeInterval(-day)
        let prevStart = prevEnd.addingTimeInterval(-Double(n - 1) * day)
        func side(_ a: Date, _ b: Date) -> (mean: Double?, count: Int) {
            let v = points.filter { $0.date >= a && $0.date <= b && $0.value.isFinite }.map(\.value)
            return (v.isEmpty ? nil : v.reduce(0, +) / Double(v.count), v.count)
        }
        let cur = side(curStart, end), prev = side(prevStart, prevEnd)
        let need = minDays ?? max(2, (n + 1) / 2)
        let direction: Direction
        if cur.count < need || prev.count < need {
            direction = .insufficient
        } else {
            let d = cur.mean! - prev.mean!
            direction = abs(d) < tolerance ? .unchanged : d > 0 ? .up : .down
        }
        return TrendPeriodComparison(currentStart: curStart, currentEnd: end, previousStart: prevStart, previousEnd: prevEnd,
                                days: n, currentMean: cur.mean, previousMean: prev.mean,
                                currentCount: cur.count, previousCount: prev.count, direction: direction)
    }
}

/// Time in HR zones 1–5 over a set of scored days, from the same awake supported seconds each day's load was computed
/// from (`DayLoadRecord.summary.zoneSeconds`). Unrecorded time and sleep are in no zone; Zone 0 is left out on purpose.
public struct ZoneTotals: Equatable, Sendable {
    /// Seconds per zone, index 0 = Zone 1 … index 4 = Zone 5.
    public let seconds: [Int]
    /// Days that contributed (had a scored summary).
    public let days: Int
    /// All supported awake seconds in those days (Zone 0 included), for context.
    public let observedS: Int

    public var totalS: Int { seconds.reduce(0, +) }

    public static func sum(_ records: [DayLoadRecord]) -> ZoneTotals {
        var s = [Int](repeating: 0, count: 5), days = 0, observed = 0
        // One record per day: a duplicate day must not count twice.
        var seen = Set<String>()
        for r in records where seen.insert(r.day).inserted {
            guard let z = r.summary?.zoneSeconds, z.count >= 6 else { continue }
            for i in 1...5 { s[i - 1] += z[i] }
            days += 1
            observed += r.summary?.observedS ?? 0
        }
        return ZoneTotals(seconds: s, days: days, observedS: observed)
    }
}
