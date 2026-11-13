import XCTest
@testable import StrandDesign

/// Issue #18: missing days break a trend line instead of being bridged.
final class TrendChartGapTests: XCTestCase {
    private func p(_ day: Double) -> TrendPoint { TrendPoint(date: Date(timeIntervalSince1970: day * 86_400), value: day) }

    func testConsecutiveDaysShareARun() {
        XCTAssertEqual(TrendChart.runs([p(0), p(1), p(2)], maxGap: 1.5 * 86_400), [0, 0, 0])
    }

    func testAMissingDayStartsANewRun() {
        XCTAssertEqual(TrendChart.runs([p(0), p(1), p(3), p(4), p(10)], maxGap: 1.5 * 86_400), [0, 0, 1, 1, 2])
    }

    func testNoGapLimitKeepsOneRun() {
        XCTAssertEqual(TrendChart.runs([p(0), p(5), p(30)], maxGap: nil), [0, 0, 0])
    }

    // MARK: daily (UTC-midnight) axis and tooltip — issue #18 audit

    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: Double(20_000 + n) * 86_400) }

    func testDailySeriesIsRecognisedOnlyOnUTCMidnights() {
        XCTAssertTrue(TrendChart.isDailyUTC([TrendPoint(date: day(0), value: 1), TrendPoint(date: day(3), value: 2)]))
        XCTAssertFalse(TrendChart.isDailyUTC([TrendPoint(date: day(0).addingTimeInterval(3600), value: 1)]))
        XCTAssertFalse(TrendChart.isDailyUTC([]))
    }

    func testShortDailySpanGetsOneTickPerDayAndLongSpansStayAutomatic() {
        let two = [TrendPoint(date: day(0), value: 1), TrendPoint(date: day(1), value: 2)]
        XCTAssertEqual(TrendChart.dayTicks(two), [day(0), day(1)])
        let gap = [TrendPoint(date: day(0), value: 1), TrendPoint(date: day(3), value: 2)]
        XCTAssertEqual(TrendChart.dayTicks(gap)?.count, 4, "missing days still get their tick; no value is drawn there")
        XCTAssertNil(TrendChart.dayTicks((0..<30).map { TrendPoint(date: day($0), value: 1) }))
        XCTAssertNil(TrendChart.dayTicks([TrendPoint(date: day(0).addingTimeInterval(60), value: 1)]), "intraday series keep automatic ticks")
    }

    func testDailyLabelsUseTheStoredCalendarDayInEveryTimeZone() {
        // 2024-10-04 00:00 UTC is still Oct 3 in the Americas; the label must say the 4th.
        let d = day(0)
        XCTAssertEqual(d, Date(timeIntervalSince1970: 1_728_000_000))
        XCTAssertTrue(TrendChart.dayAxisLabel(d).contains("4"))
        XCTAssertTrue(TrendChart.tooltipLabel(d, daily: true).contains("4 Oct"), TrendChart.tooltipLabel(d, daily: true))
    }

    func testLongDailySpansUseCompactMonthYearLabels() {
        XCTAssertFalse(TrendChart.spansYears((0..<180).map { TrendPoint(date: day($0), value: 1) }))
        XCTAssertTrue(TrendChart.spansYears((0..<400).map { TrendPoint(date: day($0), value: 1) }))
        XCTAssertEqual(TrendChart.monthYearAxisLabel(day(0)), "Oct '24")
    }
}
