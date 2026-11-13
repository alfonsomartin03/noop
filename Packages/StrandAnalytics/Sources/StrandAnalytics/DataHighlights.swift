import Foundation

// DataHighlights.swift — personal records, longest streaks and notable extremes over a range, for one source at a time.
// Display only: nothing here feeds a score.
//
// Rules (issue #13):
// - Days are local calendar day keys ("YYYY-MM-DD"), so DST never shortens or lengthens a day here. Calendar arithmetic
//   on the keys uses a fixed Gregorian/UTC calendar.
// - Only completed days count: the latest eligible day is the day before `today`. Today's unfinished values never set a
//   record or extend a streak.
// - Ranges end at that latest completed day. `month1` starts one calendar month earlier plus one day (2026-11-08 →
//   2026-10-09…2026-11-08; a month-end start clamps, so 03-31 → 03-01…03-31). `month3` is the same with three months.
//   `allTime` has no start.
// - One source at a time (WHOOP import or NOOP). Sources are never mixed into one record or streak, and each source's
//   thresholds are labelled with their own definition.
// - Missing or implausible values are dropped, never zero. A duplicate day keeps the last value given for it.
// - Ties keep the most recent day and report how many days share the value.
// - A streak is consecutive calendar days that each have a qualifying value; a missing day ends it (it is not a "miss",
//   just no evidence). Streaks are clipped to the range; ties keep the most recent.

public enum HighlightRange: String, CaseIterable, Sendable {
    case month1 = "1M", month3 = "3M", allTime = "All Time"

    var months: Int? {
        switch self {
        case .month1: return 1
        case .month3: return 3
        case .allTime: return nil
        }
    }
}

public enum HighlightSource: String, CaseIterable, Sendable {
    case whoop, noop
    public var label: String { self == .whoop ? "WHOOP import" : "NOOP" }
}

/// One source's daily values. Any series may be empty. NOOP's sleep performance is `SleepPerformance`, not WHOOP's.
public struct HighlightInputs: Sendable {
    public var sleepPerformance: [(day: String, value: Double)]
    public var recovery: [(day: String, value: Double)]
    public var strain: [(day: String, value: Double)]
    public var restingHR: [(day: String, value: Double)]
    public var hrv: [(day: String, value: Double)]
    public init(sleepPerformance: [(day: String, value: Double)] = [], recovery: [(day: String, value: Double)] = [],
                strain: [(day: String, value: Double)] = [], restingHR: [(day: String, value: Double)] = [],
                hrv: [(day: String, value: Double)] = []) {
        self.sleepPerformance = sleepPerformance; self.recovery = recovery; self.strain = strain
        self.restingHR = restingHR; self.hrv = hrv
    }
    public var isEmpty: Bool {
        sleepPerformance.isEmpty && recovery.isEmpty && strain.isEmpty && restingHR.isEmpty && hrv.isEmpty
    }
}

public struct HighlightRecord: Equatable, Sendable {
    public let value: Double
    /// Most recent day holding the value.
    public let day: String
    /// Days in the range sharing the value (1 = unique).
    public let tieCount: Int
    /// Eligible days the record was chosen from.
    public let sampleCount: Int
}

public struct HighlightStreak: Equatable, Sendable {
    public let days: Int
    public let startDay: String
    public let endDay: String
    /// True when the streak touches the range's first day, so it may have begun earlier.
    public let clippedAtStart: Bool
    /// Eligible days checked in the range.
    public let sampleCount: Int
}

public struct HighlightThresholds: Equatable, Sendable {
    public let sleepPerformanceMin: Double
    public let greenRecoveryMin: Double
    public let strainMin: Double
    public let sleepLabel: String
    public let recoveryLabel: String
    public let strainLabel: String

    public static func `for`(_ source: HighlightSource) -> HighlightThresholds {
        switch source {
        case .whoop:
            return HighlightThresholds(sleepPerformanceMin: 70, greenRecoveryMin: 67, strainMin: 10,
                                       sleepLabel: "WHOOP sleep performance ≥ 70 %",
                                       recoveryLabel: "WHOOP green recovery (≥ 67 %, WHOOP's band)",
                                       strainLabel: "WHOOP day strain ≥ 10")
        case .noop:
            return HighlightThresholds(sleepPerformanceMin: 70, greenRecoveryMin: RecoveryScorer.bandYellowMax, strainMin: 10,
                                       sleepLabel: "NOOP sleep performance ≥ 70 % (hours vs estimated need)",
                                       recoveryLabel: "NOOP recovery ≥ \(Int(RecoveryScorer.bandYellowMax)) % (NOOP's green band)",
                                       strainLabel: "NOOP day strain ≥ 10 (NOOP's 0–21 scale)")
        }
    }
}

public struct DataHighlights: Equatable, Sendable {
    public let range: HighlightRange
    public let source: HighlightSource
    /// First and last day of the range (`start` nil for all time with no data).
    public let startDay: String?
    public let endDay: String
    public let thresholds: HighlightThresholds

    public let bestSleep: HighlightRecord?
    public let peakRecovery: HighlightRecord?
    public let maxStrain: HighlightRecord?
    public let sleepStreak: HighlightStreak?
    public let greenStreak: HighlightStreak?
    public let strainStreak: HighlightStreak?
    public let lowestRHR: HighlightRecord?
    public let highestRHR: HighlightRecord?
    public let lowestHRV: HighlightRecord?
    public let highestHRV: HighlightRecord?

    /// Distinct completed days with any value in the range.
    public let eligibleDays: Int
    /// First eligible day in the source's whole history (for "partial history" captions).
    public let historyStartDay: String?

    /// The range began before this source's history did.
    public var isPartialHistory: Bool {
        guard let s = startDay, let h = historyStartDay else { return false }
        return h > s
    }

    /// Plausible values per metric; anything outside is treated as invalid, not as an extreme.
    static let plausible: (sleep: ClosedRange<Double>, recovery: ClosedRange<Double>, strain: ClosedRange<Double>,
                           rhr: ClosedRange<Double>, hrv: ClosedRange<Double>) =
        (0...100, 0...100, 0...21, 25...200, 1...300)

    public static func compute(_ inputs: HighlightInputs, source: HighlightSource, range: HighlightRange,
                               today: String) -> DataHighlights {
        let end = HighlightCalendar.addDays(today, -1) ?? today
        let start = range.months.flatMap { HighlightCalendar.rangeStart(end: end, months: $0) }
        let p = plausible
        let sleep = clean(inputs.sleepPerformance, p.sleep, end: end)
        let rec = clean(inputs.recovery, p.recovery, end: end)
        let str = clean(inputs.strain, p.strain, end: end)
        let rhr = clean(inputs.restingHR, p.rhr, end: end)
        let hrv = clean(inputs.hrv, p.hrv, end: end)
        let historyStart = [sleep, rec, str, rhr, hrv].compactMap { $0.keys.min() }.min()

        func window(_ m: [String: Double]) -> [String: Double] {
            guard let start else { return m }
            return m.filter { $0.key >= start }
        }
        let ws = window(sleep), wr = window(rec), wt = window(str), wh = window(rhr), wv = window(hrv)
        let th = HighlightThresholds.for(source)
        let first = start ?? [ws, wr, wt, wh, wv].compactMap { $0.keys.min() }.min()
        let eligible = Set(ws.keys).union(wr.keys).union(wt.keys).union(wh.keys).union(wv.keys).count

        return DataHighlights(
            range: range, source: source, startDay: first, endDay: end, thresholds: th,
            bestSleep: record(ws, highest: true), peakRecovery: record(wr, highest: true), maxStrain: record(wt, highest: true),
            sleepStreak: streak(ws, start: first, end: end) { $0 >= th.sleepPerformanceMin },
            greenStreak: streak(wr, start: first, end: end) { $0 >= th.greenRecoveryMin },
            strainStreak: streak(wt, start: first, end: end) { $0 >= th.strainMin },
            lowestRHR: record(wh, highest: false), highestRHR: record(wh, highest: true),
            lowestHRV: record(wv, highest: false), highestHRV: record(wv, highest: true),
            eligibleDays: eligible, historyStartDay: historyStart)
    }

    /// Completed, plausible, de-duplicated values (last given wins), keyed by day.
    static func clean(_ points: [(day: String, value: Double)], _ ok: ClosedRange<Double>, end: String) -> [String: Double] {
        var out: [String: Double] = [:]
        for p in points where p.value.isFinite && ok.contains(p.value) && p.day <= end && HighlightCalendar.date(p.day) != nil {
            out[p.day] = p.value
        }
        return out
    }

    static func record(_ m: [String: Double], highest: Bool) -> HighlightRecord? {
        guard let best = highest ? m.values.max() : m.values.min() else { return nil }
        // Compare at display precision so 71.96 and 72.0 count as the same record.
        let key = { (v: Double) in (v * 10).rounded() }
        let tied = m.filter { key($0.value) == key(best) }.keys.sorted()
        return HighlightRecord(value: best, day: tied.last!, tieCount: tied.count, sampleCount: m.count)
    }

    static func streak(_ m: [String: Double], start: String?, end: String, qualifies: (Double) -> Bool) -> HighlightStreak? {
        let days = m.filter { qualifies($0.value) }.keys.sorted()
        guard !days.isEmpty else { return nil }
        var best: (len: Int, s: String, e: String)?
        var runStart = days[0], prev = days[0], len = 1
        func close() {
            if best == nil || len >= best!.len { best = (len, runStart, prev) }   // >= keeps the most recent tie
        }
        for d in days.dropFirst() {
            if HighlightCalendar.addDays(prev, 1) == d { len += 1 } else { close(); runStart = d; len = 1 }
            prev = d
        }
        close()
        guard let b = best else { return nil }
        return HighlightStreak(days: b.len, startDay: b.s, endDay: b.e, clippedAtStart: start.map { b.s <= $0 } ?? false,
                               sampleCount: m.count)
    }
}

/// Day-key arithmetic on a fixed calendar, so local DST transitions can't shift a day.
public enum HighlightCalendar {
    static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.calendar = cal; f.timeZone = cal.timeZone; f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public static func date(_ day: String) -> Date? { day.count == 10 ? fmt.date(from: day) : nil }
    public static func string(_ date: Date) -> String { fmt.string(from: date) }

    public static func addDays(_ day: String, _ n: Int) -> String? {
        date(day).flatMap { cal.date(byAdding: .day, value: n, to: $0) }.map(string)
    }

    /// First day of a range of `months` calendar months ending (inclusive) on `end`.
    public static func rangeStart(end: String, months: Int) -> String? {
        guard let e = date(end), let next = cal.date(byAdding: .day, value: 1, to: e),
              let back = cal.date(byAdding: .month, value: -months, to: next) else { return nil }
        // Month-end clamping: one month before Mar 31 → Feb 28 (+1 day = Mar 1), never a day in February twice.
        let comps = cal.dateComponents([.day], from: next)
        let backComps = cal.dateComponents([.day], from: back)
        if let d = comps.day, let b = backComps.day, b < d, let fixed = cal.date(byAdding: .day, value: 1, to: back) {
            return string(fixed)
        }
        return string(back)
    }
}
