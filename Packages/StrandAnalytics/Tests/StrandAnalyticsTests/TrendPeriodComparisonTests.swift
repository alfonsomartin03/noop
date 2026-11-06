import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class TrendPeriodComparisonTests: XCTestCase {
    let d0 = Date(timeIntervalSince1970: 1_793_577_600)   // a UTC midnight
    func day(_ k: Int) -> Date { d0.addingTimeInterval(Double(k) * 86_400) }
    func pts(_ values: [Int: Double]) -> [(date: Date, value: Double)] { values.map { (day($0.key), $0.value) } }

    func testPeriodsAreEqualAdjacentWholeDays() {
        let c = TrendPeriodComparison.compare(pts([:]), days: 7, latest: day(20), today: day(30), tolerance: 1)!
        XCTAssertEqual(c.currentEnd, day(20)); XCTAssertEqual(c.currentStart, day(14))
        XCTAssertEqual(c.previousEnd, day(13)); XCTAssertEqual(c.previousStart, day(7))
        XCTAssertEqual(c.direction, .insufficient, "no data is not zero")
        XCTAssertNil(c.delta)
    }

    func testInProgressTodayIsLeftOut() {
        // Today (day 20) has a partial strain of 2; the complete days are all 10.
        var v: [Int: Double] = [:]
        for k in 6...19 { v[k] = 10 }
        v[20] = 2
        let c = TrendPeriodComparison.compare(pts(v), days: 7, latest: day(20), today: day(20), tolerance: 0.5)!
        XCTAssertEqual(c.currentEnd, day(19))
        XCTAssertEqual(c.direction, .unchanged)
        XCTAssertEqual(c.currentMean, 10)
    }

    func testUpDownUnchangedAndInsufficient() {
        var v: [Int: Double] = [:]
        for k in 0..<7 { v[k] = 50 }; for k in 7..<14 { v[k] = 55 }
        XCTAssertEqual(TrendPeriodComparison.compare(pts(v), days: 7, latest: day(13), today: nil, tolerance: 1)!.direction, .up)
        XCTAssertEqual(TrendPeriodComparison.compare(pts(v), days: 7, latest: day(13), today: nil, tolerance: 1)!.delta, 5)
        var w: [Int: Double] = [:]
        for k in 0..<7 { w[k] = 55 }; for k in 7..<14 { w[k] = 50 }
        XCTAssertEqual(TrendPeriodComparison.compare(pts(w), days: 7, latest: day(13), today: nil, tolerance: 1)!.direction, .down)
        var u: [Int: Double] = [:]
        for k in 0..<14 { u[k] = 50 + (k % 2 == 0 ? 0.2 : 0) }
        XCTAssertEqual(TrendPeriodComparison.compare(pts(u), days: 7, latest: day(13), today: nil, tolerance: 1)!.direction, .unchanged)
        // Only 2 of 7 days in the previous period: below the half-period minimum.
        let sparse = pts([0: 40, 1: 40] .merging((7..<14).map { ($0, 60.0) }, uniquingKeysWith: { a, _ in a }))
        XCTAssertEqual(TrendPeriodComparison.compare(sparse, days: 7, latest: day(13), today: nil, tolerance: 1)!.direction, .insufficient)
    }

    func testMissingDaysAreNotZero() {
        // Previous period: four days at 60 and three missing. A zero-fill would read as a big rise.
        var v: [Int: Double] = [0: 60, 2: 60, 4: 60, 6: 60]
        for k in 7..<14 { v[k] = 60 }
        let c = TrendPeriodComparison.compare(pts(v), days: 7, latest: day(13), today: nil, tolerance: 1)!
        XCTAssertEqual(c.previousMean, 60); XCTAssertEqual(c.previousCount, 4)
        XCTAssertEqual(c.direction, .unchanged)
    }

    func testZoneTotalsSumZones1To5OnceAndExcludeZone0AndGaps() {
        let t0 = 1_793_577_600
        // A day with 30 min at ~150 bpm (Zone 3–4 for HRmax 190) and nothing else: the rest of the day is unrecorded.
        let hr = (0..<1800).map { HRSample(ts: t0 + 3600 + $0, bpm: 150) }
        let support = SupportedHR(raw: hr)
        let cal = HRCalibration.resolve(declaredMax: 190, age: 30, declaredResting: 55)
        let rec = DayLoadRecord.compute(day: "d", span: TimeSpan(t0, t0 + 86_400), support: support, sessions: [],
                                        calibration: cal, quality: HRQuality.cleanWithReport(hr).1)
        let other = DayLoadRecord.compute(day: "e", span: TimeSpan(t0, t0 + 86_400), support: support, sessions: [],
                                          calibration: cal, quality: HRQuality.cleanWithReport(hr).1)
        let z = ZoneTotals.sum([rec, rec, other])
        XCTAssertEqual(z.days, 2, "a duplicated day counts once")
        XCTAssertEqual(z.seconds.count, 5)
        XCTAssertEqual(z.totalS, 2 * (rec.summary!.zoneSeconds[1...5].reduce(0, +)))
        XCTAssertLessThanOrEqual(z.totalS, 2 * 1800 + 20, "unrecorded time is in no zone")
        XCTAssertEqual(z.observedS, 2 * rec.summary!.observedS)
    }
}
