import XCTest
@testable import StrandAnalytics

/// #49 input windows (synthetic days). Engineering rules, not clinical validation.
final class FunctionalAgeSnapshotTests: XCTestCase {
    typealias S = FunctionalAgeSnapshot
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()
    /// 2026-11-18 14:00 EST.
    private lazy var asOf = cal.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 14))!
    private lazy var birth = cal.date(from: DateComponents(year: 1986, month: 5, day: 18))!

    private func dayString(_ back: Int) -> String {
        let d = cal.date(byAdding: .day, value: -back, to: cal.startOfDay(for: asOf))!
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// `n` consecutive completed days ending yesterday.
    private func days(_ n: Int, rhr: (Int) -> Double? = { _ in 60 }, sleep: (Int) -> Double? = { _ in 7.5 },
                      imported: (Int) -> Bool = { _ in false }) -> [S.Day] {
        (1...n).map { b in
            S.Day(day: dayString(b), restingHR: rhr(b).map { S.Reading(value: $0, imported: imported(b)) },
                  sleepHours: sleep(b).map { S.Reading(value: $0, imported: imported(b)) })
        }
    }

    private lazy var vo2 = S.MeasuredVO2(value: 7.9 * 3.5, method: "treadmill CPET",
                                         testedAt: cal.date(byAdding: .month, value: -3, to: asOf)!)

    func testOldOrFutureVO2TestIsNotUsed() {
        let old = S.MeasuredVO2(value: 40, method: "CPET", testedAt: cal.date(byAdding: .year, value: -3, to: asOf)!)
        let s = S.summarize(days: days(200), birth: birth, asOf: asOf, calendar: cal, measuredVO2: old)
        XCTAssertNil(s.current)
        XCTAssertTrue(s.reasons.contains { $0.contains("more than 2 years old") })
        let future = S.MeasuredVO2(value: 40, method: "CPET", testedAt: asOf.addingTimeInterval(86_400))
        XCTAssertTrue(S.summarize(days: days(200), birth: birth, asOf: asOf, calendar: cal, measuredVO2: future)
            .reasons.contains("Measured VO₂max: test date is in the future"))
    }

    func testWindowExcludesTodayAndSpansDST() {
        let w = S.windowDays(asOf: asOf, length: 30, calendar: cal)
        XCTAssertEqual(w.count, 30)
        XCTAssertFalse(w.contains("2026-11-18"), "today is in progress")
        XCTAssertTrue(w.contains("2026-11-17"))
        XCTAssertTrue(w.contains("2026-11-01"), "the DST day is one day")
        XCTAssertTrue(w.contains("2026-10-19"))
        XCTAssertFalse(w.contains("2026-10-18"))
    }

    func testCompleteNeutralHistoryGivesChronologicalAgeAndPaceOne() throws {
        let s = S.summarize(days: days(200), birth: birth, asOf: asOf, calendar: cal, measuredVO2: vo2)
        XCTAssertEqual(s.reasons, [])
        let c = try XCTUnwrap(s.current)
        XCTAssertEqual(c.totalImpact, 0, accuracy: 1e-12)
        XCTAssertEqual(c.chronologicalAge, try XCTUnwrap(FunctionalAge.chronologicalAge(birth: birth, asOf: asOf)), accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(s.pace), 1.0, accuracy: 1e-12)
        XCTAssertEqual(s.horizonEnd, cal.date(byAdding: .month, value: 6, to: asOf))
    }

    func testRecentImprovementSlowsPace() throws {
        // Resting HR 70 for the older days, 60 for the last 30: current median 70 (150 of 180 days), projected 60.
        let s = S.summarize(days: days(200, rhr: { $0 <= 30 ? 60 : 70 }), birth: birth, asOf: asOf, calendar: cal,
                            measuredVO2: vo2)
        let c = try XCTUnwrap(s.current)
        XCTAssertEqual(c.totalImpact, log(1.09) / 0.1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(s.projectedImpact), 0, accuracy: 1e-12)
        let h = try XCTUnwrap(s.horizonEnd).timeIntervalSince(asOf) / FunctionalAge.secondsPerYear
        XCTAssertEqual(try XCTUnwrap(s.pace), 1 - (log(1.09) / 0.1) / h, accuracy: 1e-9)
        XCTAssertLessThan(try XCTUnwrap(s.pace), 1)
    }

    func testOneSourcePerWindowAndMedian() {
        // 100 NOOP days at 55 bpm, 80 imported days at 65 bpm inside the long window: NOOP wins, imports never mix.
        let d = days(180, rhr: { $0 <= 100 ? 55 : 65 }, imported: { $0 > 100 })
        let ins = S.inputs(days: d, window: S.windowDays(asOf: asOf, length: 180, calendar: cal), minDays: 90, measuredVO2: nil)
        let rhr = ins.first { $0.contributor == .restingHR }!
        XCTAssertEqual(rhr.value, 55)
        XCTAssertEqual(rhr.source, .noop)
        XCTAssertEqual(rhr.coveredDays, 100)
        // More imported days than NOOP days: imported wins.
        let d2 = days(180, rhr: { $0 <= 60 ? 55 : 65 }, imported: { $0 > 60 })
        let r2 = S.inputs(days: d2, window: S.windowDays(asOf: asOf, length: 180, calendar: cal), minDays: 90, measuredVO2: nil)
            .first { $0.contributor == .restingHR }!
        XCTAssertEqual(r2.value, 65)
        XCTAssertEqual(r2.source, .imported)
        XCTAssertEqual(r2.coveredDays, 120)
        XCTAssertEqual(S.median([3, 1, 2, 10]), 2.5)
    }

    func testSparseHistoryAndMissingInputsGiveReasonsNotNumbers() {
        let s = S.summarize(days: days(40), birth: nil, asOf: asOf, calendar: cal, measuredVO2: nil)
        XCTAssertNil(s.current)
        XCTAssertNil(s.pace)
        XCTAssertTrue(s.reasons.contains("Birth date (Settings ▸ Profile)"))
        XCTAssertTrue(s.reasons.contains { $0.contains("measured VO₂max") && $0.contains("#42") })
        XCTAssertTrue(s.reasons.contains("Last 180 days — Resting heart rate: 40 of 90 days with complete data"))
        // Sleep on every third night: 60 of 180 days, below the 90-day minimum.
        let gaps = S.summarize(days: days(200, sleep: { $0 % 3 == 0 ? 7 : nil }), birth: birth, asOf: asOf,
                               calendar: cal, measuredVO2: vo2)
        XCTAssertNil(gaps.current, "missing sleep nights are coverage, never zeros")
        XCTAssertTrue(gaps.reasons.contains("Last 180 days — Sleep duration: 60 of 90 days with complete data"))
        // Every other night: exactly 90, enough.
        let enough = S.summarize(days: days(200, sleep: { $0 % 2 == 0 ? 7 : nil }), birth: birth, asOf: asOf,
                                 calendar: cal, measuredVO2: vo2)
        XCTAssertNotNil(enough.current)
    }

    func testFutureAndTodayRowsAreIgnored() throws {
        var d = days(200)
        d.append(S.Day(day: "2026-11-18", restingHR: S.Reading(value: 120, imported: false), sleepHours: nil))
        d.append(S.Day(day: "2026-11-19", restingHR: S.Reading(value: 120, imported: false), sleepHours: nil))
        let s = S.summarize(days: d, birth: birth, asOf: asOf, calendar: cal, measuredVO2: vo2)
        XCTAssertEqual(try XCTUnwrap(s.current).totalImpact, 0, accuracy: 1e-12)
    }
}
