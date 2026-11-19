import Foundation

/// Turns per-day data into `FunctionalAge` inputs over fixed windows, then into the current estimate, the projected
/// estimate and the pace (#49). Pure; the app supplies the days.
///
/// Engineering choices (frozen 2026-11-18, before any evaluation; documented in docs/HEALTH_MODELS.md):
/// - Long window = the 180 completed local days before `asOf` (today excluded), at least 90 days per contributor.
///   It gives the CURRENT functional age.
/// - Short window = the 30 completed days before `asOf`, at least 20 days. Its inputs, held for the horizon, give the
///   PROJECTED age impact; pace compares the two over a 6-calendar-month horizon (true length from the calendar).
/// - Value per window = median of the daily values. One source per contributor per window: the source (NOOP or
///   import) with more days in that window, NOOP on a tie; sources never mix inside a window.
/// - Daily steps are not used until #42 validates completeness: they always report "not validated yet".
public enum FunctionalAgeSnapshot {
    public static let longWindowDays = 180, longMinDays = 90
    public static let shortWindowDays = 30, shortMinDays = 20
    public static let horizonMonths = 6
    /// Pace smoothing (owner decision 2026-11-19; pace is a display feature, not a validated prediction): the
    /// projected impact is the mean of the 30-day impacts at the as-of date and the 7 weekly dates before it (each
    /// that is ready; the as-of date itself must be). Replay: week-to-week |Δ pace| median 0.09× → 0.06×,
    /// p90 0.27× → 0.11× (4 weeks: p90 0.17×, 6 weeks: 0.13×).
    public static let paceSmoothingWeeks = 8

    public struct Reading: Equatable, Sendable {
        public let value: Double
        public let imported: Bool
        public init(value: Double, imported: Bool) { self.value = value; self.imported = imported }
    }

    /// One local calendar day ("YYYY-MM-DD", as `DailyMetric.day`).
    public struct Day: Equatable, Sendable {
        public let day: String
        public let restingHR: Reading?
        public let sleepHours: Reading?
        public init(day: String, restingHR: Reading?, sleepHours: Reading?) {
            self.day = day; self.restingHR = restingHR; self.sleepHours = sleepHours
        }
    }

    /// A VO₂max the wearer entered from a test (value in ml/kg/min, method text, test date). Older than
    /// `maxVO2AgeYears` = stale (fitness changes; engineering choice).
    public struct MeasuredVO2: Equatable, Sendable {
        public let value: Double
        public let method: String
        public let testedAt: Date
        public init(value: Double, method: String, testedAt: Date) {
            self.value = value; self.method = method; self.testedAt = testedAt
        }
    }
    public static let maxVO2AgeYears = 2.0

    /// The `length` completed local days before `asOf`'s local day, as "YYYY-MM-DD".
    public static func windowDays(asOf: Date, length: Int, calendar: Calendar) -> Set<String> {
        let f = DateFormatter()
        f.calendar = calendar; f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        let today = calendar.startOfDay(for: asOf)
        return Set((1...max(length, 1)).compactMap { calendar.date(byAdding: .day, value: -$0, to: today).map(f.string) })
    }

    static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted(), n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// Inputs for one window.
    public static func inputs(days: [Day], window: Set<String>, minDays: Int,
                              measuredVO2: MeasuredVO2?) -> [FunctionalAge.Input] {
        let inWindow = days.filter { window.contains($0.day) }
        func input(_ c: FunctionalAge.Contributor, _ pick: (Day) -> Reading?) -> FunctionalAge.Input {
            let readings = inWindow.compactMap(pick).filter { $0.value.isFinite }
            let noop = readings.filter { !$0.imported }, imp = readings.filter { $0.imported }
            let chosen = imp.count > noop.count ? imp : noop
            return FunctionalAge.Input(contributor: c, value: chosen.isEmpty ? nil : median(chosen.map(\.value)),
                                       source: imp.count > noop.count ? .imported : .noop,
                                       coveredDays: chosen.count, requiredDays: minDays)
        }
        var out = [input(.restingHR, \.restingHR), input(.sleepDuration, \.sleepHours)]
        if let v = measuredVO2 {
            out.append(FunctionalAge.Input(contributor: .vo2max, value: v.value, source: .manual(method: v.method),
                                           coveredDays: minDays, requiredDays: minDays))
        }
        return out
    }

    public struct Summary: Equatable, Sendable {
        public let current: FunctionalAge.Estimate?
        public let projectedImpact: Double?
        public let pace: Double?
        public let horizonEnd: Date?
        /// Everything that blocks a number, in display order (empty when `current` and `pace` exist).
        public let reasons: [String]
    }

    public static func summarize(days: [Day], birth: Date?, asOf: Date, calendar: Calendar,
                                 measuredVO2: MeasuredVO2? = nil, smoothingWeeks: Int = paceSmoothingWeeks) -> Summary {
        var reasons: [String] = []
        let age = birth.flatMap { FunctionalAge.chronologicalAge(birth: $0, asOf: asOf) }
        if age == nil { reasons.append("Birth date (Settings ▸ Profile)") }
        var measuredVO2 = measuredVO2
        if let v = measuredVO2 {
            let ageYears = asOf.timeIntervalSince(v.testedAt) / FunctionalAge.secondsPerYear
            if ageYears > maxVO2AgeYears || ageYears < 0 {
                reasons.append(ageYears < 0 ? "Measured VO₂max: test date is in the future"
                                            : "Measured VO₂max: test is more than \(Int(maxVO2AgeYears)) years old — enter a recent one")
                measuredVO2 = nil
            }
        } else {
            reasons.append("Activity or fitness: enter a measured VO₂max in Settings ▸ Profile (daily steps are not validated yet, #42)")
        }
        let long = inputs(days: days, window: windowDays(asOf: asOf, length: longWindowDays, calendar: calendar),
                          minDays: longMinDays, measuredVO2: measuredVO2)
        let short = inputs(days: days, window: windowDays(asOf: asOf, length: shortWindowDays, calendar: calendar),
                           minDays: shortMinDays, measuredVO2: measuredVO2)
        for i in long { reasons += FunctionalAge.inputProblems(i).map { "Last \(longWindowDays) days — \($0)" } }
        for i in short { reasons += FunctionalAge.inputProblems(i).map { "Last \(shortWindowDays) days — \($0)" } }
        let current = age.flatMap { FunctionalAge.estimate(inputs: long, chronologicalAge: $0).0 }
        let projected = age.flatMap { a -> Double? in
            guard let now = FunctionalAge.estimate(inputs: short, chronologicalAge: a).0?.totalImpact else { return nil }
            var impacts = [now]
            for k in stride(from: 1, to: max(smoothingWeeks, 1), by: 1) {
                guard let t = calendar.date(byAdding: .day, value: -7 * k, to: asOf) else { continue }
                let w = inputs(days: days, window: windowDays(asOf: t, length: shortWindowDays, calendar: calendar),
                               minDays: shortMinDays, measuredVO2: measuredVO2)
                if let i = FunctionalAge.estimate(inputs: w, chronologicalAge: a).0?.totalImpact { impacts.append(i) }
            }
            return impacts.reduce(0, +) / Double(impacts.count)
        }
        let end = calendar.date(byAdding: .month, value: horizonMonths, to: asOf)
        let pace = current.flatMap { c in projected.flatMap { p in end.flatMap {
            FunctionalAge.pace(currentImpact: c.totalImpact, projectedImpact: p, from: asOf, to: $0) } } }
        return Summary(current: current, projectedImpact: projected, pace: pace, horizonEnd: end,
                       reasons: current != nil && pace != nil ? [] : reasons)
    }
}
