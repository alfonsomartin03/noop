import XCTest
import WhoopStore
@testable import StrandAnalytics

/// #49 replay evaluation: synthetic daily rows only.
final class FunctionalAgeReplayTests: XCTestCase {
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    private func date(_ s: String) -> Date {
        let p = s.split(separator: "-").map { Int($0)! }
        return cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))!
    }

    private func key(_ d: Date) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// Daily rows from `from` through `to`; `rhr(day)` picks resting HR, sleep fixed at 7.5 h (impact 0).
    private func days(_ from: String, _ to: String, imported: Bool = true, skip: Set<String> = [],
                      rhr: (Date) -> Double) -> [FunctionalAgeSnapshot.Day] {
        var out: [FunctionalAgeSnapshot.Day] = [], d = date(from)
        while d <= date(to) {
            if !skip.contains(key(d)) {
                out.append(.init(day: key(d), restingHR: .init(value: rhr(d), imported: imported),
                                 sleepHours: .init(value: 7.5, imported: imported)))
            }
            d = cal.date(byAdding: .day, value: 1, to: d)!
        }
        return out
    }

    func testStableInputsGiveZeroErrorForBothAndNoWeeklyChange() throws {
        let rows = days("2025-01-01", "2026-06-30") { _ in 70 }
        let run = FunctionalAgeReplay.run(days: rows, from: date("2025-07-01"), to: date("2025-12-31"), calendar: cal)
        let r = try XCTUnwrap(FunctionalAgeReplay.report(run))
        XCTAssertGreaterThan(r.n, 20)
        XCTAssertEqual(r.projection.mae, 0, accuracy: 1e-9)
        XCTAssertEqual(r.baseline.mae, 0, accuracy: 1e-9)
        XCTAssertEqual(r.weeklyChangeMedian ?? -1, 0, accuracy: 1e-9)
        XCTAssertFalse(r.projectionSupported, "a tie is not support")
        // RHR 70 = +0.86 years (1.09 per 10 bpm), sleep 7.5 h and the neutral VO₂ = 0.
        XCTAssertEqual(run.points[0].baseline, log(1.09) / 0.1, accuracy: 1e-9)
        XCTAssertEqual(run.points[0].sources["restingHR"], "imported")
    }

    func testAStepChangeIsAnticipatedByTheProjectionNotTheBaseline() throws {
        // RHR 60 (impact 0) until 2025-09-01, then 70 for good.
        let change = date("2025-09-01")
        let rows = days("2025-01-01", "2026-06-30") { $0 < change ? 60 : 70 }
        // As-of 2025-09-29: 28 of the last 30 days are new (projection 70), 28 of 180 (current 60);
        // six months later the 180-day median is 70.
        // Single 30-day window (smoothing off): this checks the evaluation, not the smoothing.
        let run = FunctionalAgeReplay.run(days: rows, from: date("2025-09-29"), to: date("2025-09-29"), calendar: cal,
                                          smoothingWeeks: 1)
        let p = try XCTUnwrap(run.points.first)
        let d70 = log(1.09) / 0.1
        XCTAssertEqual(p.projected, d70, accuracy: 1e-9)
        XCTAssertEqual(p.baseline, 0, accuracy: 1e-9)
        XCTAssertEqual(p.realized, d70, accuracy: 1e-9)
        let r = try XCTUnwrap(FunctionalAgeReplay.report(run))
        XCTAssertTrue(r.projectionSupported)
        XCTAssertEqual(r.projectionCloser, 1)
        XCTAssertEqual(r.baseline.bias, d70, accuracy: 1e-9)
    }

    func testShortLivedChangeMisleadsTheProjection() throws {
        // A 30-day spike that reverts: the projection over-reacts, the baseline is right.
        let rows = days("2025-01-01", "2026-06-30") { d in
            (d >= self.date("2025-09-01") && d < self.date("2025-10-01")) ? 70 : 60
        }
        let run = FunctionalAgeReplay.run(days: rows, from: date("2025-10-01"), to: date("2025-10-01"), calendar: cal)
        let r = try XCTUnwrap(FunctionalAgeReplay.report(run))
        XCTAssertFalse(r.projectionSupported)
        XCTAssertEqual(r.baseline.mae, 0, accuracy: 1e-9)
    }

    func testSparseWindowsAreSkippedWithReasonsAndOverlapIsCounted() throws {
        // Data only from 2025-01-01; a 100-day hole late in 2026 starves later horizons.
        var skip = Set<String>(), d = date("2026-01-10")
        while d < date("2026-04-20") { skip.insert(key(d)); d = cal.date(byAdding: .day, value: 1, to: d)! }
        let rows = days("2025-01-01", "2026-12-31", skip: skip) { _ in 65 }
        let run = FunctionalAgeReplay.run(days: rows, from: date("2025-03-01"), to: date("2026-03-01"), calendar: cal)
        XCTAssertFalse(run.skipped.isEmpty)
        XCTAssertTrue(run.skipped.keys.contains { $0.hasPrefix("at t: ") }, "\(run.skipped)")
        XCTAssertTrue(run.skipped.keys.contains { $0.hasPrefix("at t + horizon: ") }, "\(run.skipped)")
        let r = try XCTUnwrap(FunctionalAgeReplay.report(run))
        XCTAssertLessThan(r.nonOverlapping, r.n)
        XCTAssertGreaterThanOrEqual(r.nonOverlapping, 1)
        for (a, b) in zip(run.points, run.points.dropFirst()) {
            XCTAssertEqual(cal.dateComponents([.day], from: a.asOf, to: b.asOf).day! % 7, 0)
        }
    }

    func testPaceSmoothingAveragesWeeklyThirtyDayWindows() {
        // RHR 60 until 2025-09-01, 70 after. As-of 2025-09-29 the 30-day windows at t and t−7 are mostly new (70),
        // those at t−14 … t−49 mostly old (60): smoothed projection = 2 × D(70) / 8.
        let change = date("2025-09-01")
        let rows = days("2025-01-01", "2026-06-30") { $0 < change ? 60 : 70 }
        let d70 = log(1.09) / 0.1
        func s(_ w: Int) -> FunctionalAgeSnapshot.Summary {
            FunctionalAgeReplay.summary(rows, asOf: date("2025-09-29"), calendar: cal, smoothingWeeks: w)
        }
        XCTAssertEqual(s(1).projectedImpact ?? .nan, d70, accuracy: 1e-9)
        XCTAssertEqual(s(8).projectedImpact ?? .nan, d70 / 4, accuracy: 1e-9)
        XCTAssertEqual(FunctionalAgeSnapshot.paceSmoothingWeeks, 8)
        // Stable inputs still give exactly 1.0×.
        let flat = days("2025-01-01", "2026-06-30") { _ in 65 }
        let p = FunctionalAgeReplay.summary(flat, asOf: date("2025-12-01"), calendar: cal, smoothingWeeks: 8).pace
        XCTAssertEqual(p ?? .nan, 1, accuracy: 1e-12)
        // Weeks without a ready 30-day window are left out of the mean, never counted as zero.
        let sparse = rows.filter { $0.day < "2025-08-01" || $0.day >= "2025-09-01" }
        // August removed: t and t−7 are ready (new, 70); t−14 … t−42 have < 20 days; t−49 (Jul 12–Aug 10) has 20
        // July days (60).
        XCTAssertEqual(FunctionalAgeReplay.summary(sparse, asOf: date("2025-09-29"), calendar: cal, smoothingWeeks: 8)
                        .projectedImpact ?? .nan, (d70 + d70 + 0) / 3, accuracy: 1e-9)
    }

    func testDisplayNeverShowsAFunctionalAgeBelowEighteen() {
        func est(age: Double, impact: Double) -> FunctionalAge.Estimate {
            FunctionalAge.Estimate(modelVersion: FunctionalAge.modelVersion, chronologicalAge: age, impacts: [
                .init(group: .restingHR, contributor: .restingHR, value: 60, hazardRatio: 1, years: impact, clipped: false)])
        }
        XCTAssertEqual(FunctionalAge.display(est(age: 40, impact: -3)),
                       .init(age: "37.0", difference: -3, floored: false))
        XCTAssertEqual(FunctionalAge.display(est(age: 40, impact: -22)).age, "18.0", "exactly 18 is shown")
        let low = FunctionalAge.display(est(age: 40, impact: -25))
        XCTAssertEqual(low.age, "<18")
        XCTAssertTrue(low.floored)
        XCTAssertEqual(low.difference ?? .nan, -22, accuracy: 1e-9, "a bound, never the hidden −25")
        let teen = FunctionalAge.display(est(age: 17, impact: -1))
        XCTAssertEqual(teen.age, "<18")
        XCTAssertNil(teen.difference)
    }

    func testDaysFromStoredRowsKeepSourcesApartAndDropZeroSleep() {
        func m(_ d: String, sleep: Double?, rhr: Int?) -> DailyMetric {
            DailyMetric(day: d, totalSleepMin: sleep, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                        disturbances: nil, restingHr: rhr, avgHrv: nil, recovery: nil, strain: nil, exerciseCount: nil)
        }
        let out = FunctionalAgeSnapshot.days(computed: [m("2026-11-01", sleep: 0, rhr: 55), m("2026-11-02", sleep: nil, rhr: nil)],
                                             imported: [m("2026-11-01", sleep: 450, rhr: nil)])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].restingHR, .init(value: 55, imported: false))
        XCTAssertNil(out[0].sleepHours, "0 min is missing, not zero")
        XCTAssertEqual(out[1].sleepHours, .init(value: 7.5, imported: true))
        XCTAssertNil(out[1].restingHR)
    }
}
