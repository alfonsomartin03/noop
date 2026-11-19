import Foundation
import WhoopStore

extension FunctionalAgeSnapshot {
    /// Daily inputs from stored rows: NOOP's computed rows and the imported WHOOP rows, flagged apart so a window never
    /// mixes them. Used by the Health page (`Repository.functionalAgeDays`) and the replay tool alike.
    public static func days(computed: [DailyMetric], imported: [DailyMetric]) -> [Day] {
        func day(_ m: DailyMetric, imported: Bool) -> Day? {
            let rhr = m.restingHr.map { Reading(value: Double($0), imported: imported) }
            let sleep = m.totalSleepMin.flatMap { $0 > 0 ? Reading(value: $0 / 60, imported: imported) : nil }
            return rhr == nil && sleep == nil ? nil : Day(day: m.day, restingHR: rhr, sleepHours: sleep)
        }
        return computed.compactMap { day($0, imported: false) } + imported.compactMap { day($0, imported: true) }
    }
}

/// #49 replay evaluation (design frozen in docs/HEALTH_MODELS.md before any output was seen): does the 6-month
/// projection behind the pace predict the model's own later 180-day impact better than "no change"?
/// Impacts only (functional − chronological age), so no birth date is needed; the activity/fitness group is held at
/// the neutral referent (impact 0) because one measured test is constant over time and would cancel anyway.
public enum FunctionalAgeReplay {
    /// The 7.9-MET referent in ml/kg/min: impact 0.
    public static let neutralVO2 = 7.9 * 3.5
    public static let stepDays = 7

    public struct Point: Equatable, Sendable {
        public let asOf: Date
        public let horizonEnd: Date
        /// D_projected(t): the model's prediction of the impact at the horizon end.
        public let projected: Double
        /// D_current(t): the no-change baseline.
        public let baseline: Double
        /// D_current(t + horizon).
        public let realized: Double
        /// "noop" / "imported" per contributor at t (180-day window), e.g. ["restingHR": "imported"].
        public let sources: [String: String]
        public var projectionError: Double { realized - projected }
        public var baselineError: Double { realized - baseline }
    }

    public struct Run: Equatable, Sendable {
        public let points: [Point]
        /// Grid dates without a ready estimate at t or at t + horizon, by first reason.
        public let skipped: [String: Int]
        /// D_current at every ready grid date (for week-to-week stability), in date order.
        public let currentImpacts: [Double]
        /// Raw pace at every grid date that had one, in date order (jumpiness check).
        public let paces: [Double]
    }

    /// Fixed synthetic birth date: impacts don't depend on age in v1, so any age that keeps every as-of date valid works.
    static let replayBirth = Date(timeIntervalSince1970: -40 * 365.2425 * 86_400)

    static func summary(_ days: [FunctionalAgeSnapshot.Day], asOf: Date, calendar: Calendar,
                        smoothingWeeks: Int) -> FunctionalAgeSnapshot.Summary {
        FunctionalAgeSnapshot.summarize(days: days, birth: replayBirth, asOf: asOf, calendar: calendar,
                                        measuredVO2: .init(value: neutralVO2, method: "replay-neutral", testedAt: asOf),
                                        smoothingWeeks: smoothingWeeks)
    }

    /// Grid from `from` to `to` (inclusive) every `stepDays`, at local noon. `to` should be the last as-of date whose
    /// horizon end is a completed day; the caller passes it (the replay never looks at today).
    public static func run(days: [FunctionalAgeSnapshot.Day], from: Date, to: Date, calendar: Calendar,
                           stepDays: Int = stepDays,
                           smoothingWeeks: Int = FunctionalAgeSnapshot.paceSmoothingWeeks) -> Run {
        var points: [Point] = [], skipped: [String: Int] = [:], impacts: [Double] = [], paces: [Double] = []
        var cache: [Date: FunctionalAgeSnapshot.Summary] = [:]
        func s(_ d: Date) -> FunctionalAgeSnapshot.Summary {
            if let c = cache[d] { return c }
            let v = summary(days, asOf: d, calendar: calendar, smoothingWeeks: smoothingWeeks); cache[d] = v; return v
        }
        func noon(_ d: Date) -> Date { calendar.date(bySettingHour: 12, minute: 0, second: 0, of: d) ?? d }
        var t = noon(from)
        let last = noon(to)
        while t <= last {
            let now = s(t)
            if let c = now.current { impacts.append(c.totalImpact) }
            if let p = now.pace { paces.append(p) }
            guard let c = now.current, let p = now.projectedImpact, let end = now.horizonEnd else {
                skipped["at t: " + (now.reasons.first ?? "not ready"), default: 0] += 1
                t = calendar.date(byAdding: .day, value: stepDays, to: t) ?? last.addingTimeInterval(1); continue
            }
            if let later = s(noon(end)).current {
                var src: [String: String] = [:]
                let window = FunctionalAgeSnapshot.windowDays(asOf: t, length: FunctionalAgeSnapshot.longWindowDays,
                                                              calendar: calendar)
                for i in FunctionalAgeSnapshot.inputs(days: days, window: window,
                                                      minDays: FunctionalAgeSnapshot.longMinDays, measuredVO2: nil) {
                    src[i.contributor.rawValue] = i.source == .imported ? "imported" : "noop"
                }
                points.append(Point(asOf: t, horizonEnd: end, projected: p, baseline: c.totalImpact,
                                    realized: later.totalImpact, sources: src))
            } else {
                skipped["at t + horizon: " + (s(noon(end)).reasons.first ?? "not ready"), default: 0] += 1
            }
            t = calendar.date(byAdding: .day, value: stepDays, to: t) ?? last.addingTimeInterval(1)
        }
        return Run(points: points, skipped: skipped, currentImpacts: impacts, paces: paces)
    }

    public struct Errors: Equatable, Sendable {
        public let mae: Double, medianAE: Double, bias: Double
    }

    public struct Report: Equatable, Sendable {
        public let n: Int
        /// Points spaced ≥ the horizon apart (greedy from the first): the count that is not just overlap.
        public let nonOverlapping: Int
        public let projection: Errors
        public let baseline: Errors
        /// Share of points where the projection is strictly closer than the baseline.
        public let projectionCloser: Double
        public let nonOverlappingProjection: Errors
        public let nonOverlappingBaseline: Errors
        /// |Δ D_current| between consecutive ready grid dates: median and 90th percentile, in years.
        public let weeklyChangeMedian: Double?
        public let weeklyChangeP90: Double?
        /// |Δ pace| between consecutive grid dates with a pace: median and 90th percentile (×).
        public let weeklyPaceChangeMedian: Double?
        public let weeklyPaceChangeP90: Double?
        /// Projection MAE < baseline MAE (the frozen decision rule).
        public var projectionSupported: Bool { projection.mae < baseline.mae }
    }

    static func errors(_ e: [Double]) -> Errors {
        let a = e.map(abs)
        return Errors(mae: a.reduce(0, +) / Double(a.count), medianAE: FunctionalAgeSnapshot.median(a),
                      bias: e.reduce(0, +) / Double(e.count))
    }

    static func quantile(_ xs: [Double], _ q: Double) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let pos = q * Double(s.count - 1), lo = Int(pos.rounded(.down)), hi = Int(pos.rounded(.up))
        return s[lo] + (s[hi] - s[lo]) * (pos - Double(lo))
    }

    public static func report(_ run: Run) -> Report? {
        let pts = run.points
        guard !pts.isEmpty else { return nil }
        var kept: [Point] = []
        for p in pts where kept.last.map({ p.asOf >= $0.horizonEnd }) ?? true { kept.append(p) }
        let changes = zip(run.currentImpacts, run.currentImpacts.dropFirst()).map { abs($1 - $0) }
        let paceChanges = zip(run.paces, run.paces.dropFirst()).map { abs($1 - $0) }
        return Report(n: pts.count, nonOverlapping: kept.count,
                      projection: errors(pts.map(\.projectionError)), baseline: errors(pts.map(\.baselineError)),
                      projectionCloser: Double(pts.filter { abs($0.projectionError) < abs($0.baselineError) }.count)
                          / Double(pts.count),
                      nonOverlappingProjection: errors(kept.map(\.projectionError)),
                      nonOverlappingBaseline: errors(kept.map(\.baselineError)),
                      weeklyChangeMedian: quantile(changes, 0.5), weeklyChangeP90: quantile(changes, 0.9),
                      weeklyPaceChangeMedian: quantile(paceChanges, 0.5), weeklyPaceChangeP90: quantile(paceChanges, 0.9))
    }
}
