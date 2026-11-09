import XCTest
@testable import StrandAnalytics

final class DataHighlightsTests: XCTestCase {
    private func days(from start: String, _ values: [Double?]) -> [(day: String, value: Double)] {
        values.enumerated().compactMap { i, v in v.map { (HighlightCalendar.addDays(start, i)!, $0) } }
    }

    func testMonthRangeBoundariesAndClamping() {
        XCTAssertEqual(HighlightCalendar.rangeStart(end: "2026-11-08", months: 1), "2026-10-09")
        XCTAssertEqual(HighlightCalendar.rangeStart(end: "2026-03-31", months: 1), "2026-03-01")
        XCTAssertEqual(HighlightCalendar.rangeStart(end: "2026-03-30", months: 1), "2026-03-01")
        XCTAssertEqual(HighlightCalendar.rangeStart(end: "2026-11-08", months: 3), "2026-08-09")
        // Leap year: Feb 29 exists in 2028.
        XCTAssertEqual(HighlightCalendar.rangeStart(end: "2028-02-28", months: 1), "2028-01-29")
    }

    func testDSTWeekendKeepsCalendarDaysContiguous() {
        // US DST ended 2026-11-01. Day keys must still be consecutive across it.
        XCTAssertEqual(HighlightCalendar.addDays("2026-10-31", 1), "2026-11-01")
        XCTAssertEqual(HighlightCalendar.addDays("2026-11-01", 1), "2026-11-02")
        let rec = days(from: "2026-10-30", [80, 80, 80, 80])
        let h = DataHighlights.compute(HighlightInputs(recovery: rec), source: .noop, range: .month1, today: "2026-11-05")
        XCTAssertEqual(h.greenStreak?.days, 4)
        XCTAssertEqual(h.greenStreak?.startDay, "2026-10-30")
        XCTAssertEqual(h.greenStreak?.endDay, "2026-11-02")
    }

    func testTodayIsExcluded() {
        let s = days(from: "2026-11-01", [8, 9, 20])   // 20 is today's unfinished value
        let h = DataHighlights.compute(HighlightInputs(strain: s), source: .noop, range: .allTime, today: "2026-11-03")
        XCTAssertEqual(h.endDay, "2026-11-02")
        XCTAssertEqual(h.maxStrain?.value, 9)
        XCTAssertEqual(h.maxStrain?.day, "2026-11-02")
    }

    func testGapsBreakStreaksAndAreNotZero() {
        // 3 qualifying, missing day, 2 qualifying.
        let r = days(from: "2026-10-01", [70, 75, 90, nil, 68, 99])
        let h = DataHighlights.compute(HighlightInputs(recovery: r), source: .whoop, range: .allTime, today: "2026-10-20")
        XCTAssertEqual(h.greenStreak?.days, 3)
        XCTAssertEqual(h.greenStreak?.startDay, "2026-10-01")
        XCTAssertEqual(h.greenStreak?.endDay, "2026-10-03")
        XCTAssertEqual(h.peakRecovery?.value, 99)
        XCTAssertEqual(h.peakRecovery?.sampleCount, 5)      // missing day not counted as a sample
    }

    func testStreakTieKeepsMostRecentAndClipsToRange() {
        let r = days(from: "2026-10-01", [80, 80, 10, 80, 80])
        let h = DataHighlights.compute(HighlightInputs(recovery: r), source: .noop, range: .allTime, today: "2026-10-10")
        XCTAssertEqual(h.greenStreak?.startDay, "2026-10-04")
        XCTAssertEqual(h.greenStreak?.days, 2)

        // A 1M range starting mid-streak clips it and says so.
        let long = days(from: "2026-09-01", Array(repeating: 80, count: 60))
        let m = DataHighlights.compute(HighlightInputs(recovery: long), source: .noop, range: .month1, today: "2026-10-31")
        // Ends 10-30 (today excluded); 09-31 doesn't exist, so the clamped start is 10-01.
        XCTAssertEqual(m.startDay, "2026-10-01")
        XCTAssertEqual(m.greenStreak?.startDay, "2026-10-01")
        XCTAssertEqual(m.greenStreak?.days, 30)
        XCTAssertEqual(m.greenStreak?.clippedAtStart, true)
    }

    func testRecordTiesReportCountAndLatestDay() {
        let s = days(from: "2026-10-01", [12.0, 15.0, 9.0, 15.0, 15.02])
        let h = DataHighlights.compute(HighlightInputs(strain: s), source: .noop, range: .allTime, today: "2026-10-20")
        XCTAssertEqual(h.maxStrain?.day, "2026-10-05")
        XCTAssertEqual(h.maxStrain?.tieCount, 3)
    }

    func testDuplicateDaysAndInvalidValues() {
        let rhr: [(day: String, value: Double)] = [("2026-10-01", 60), ("2026-10-01", 55), ("2026-10-02", 0),
                                                   ("2026-10-03", .nan), ("2026-10-04", 52), ("bad", 40)]
        let h = DataHighlights.compute(HighlightInputs(restingHR: rhr), source: .whoop, range: .allTime, today: "2026-10-10")
        XCTAssertEqual(h.lowestRHR?.value, 52)
        XCTAssertEqual(h.highestRHR?.value, 55)       // the later duplicate replaced 60
        XCTAssertEqual(h.lowestRHR?.sampleCount, 2)
        XCTAssertEqual(h.eligibleDays, 2)
    }

    func testEmptyAndMissingSeriesGiveNilNotZero() {
        let h = DataHighlights.compute(HighlightInputs(), source: .noop, range: .month3, today: "2026-10-10")
        XCTAssertNil(h.bestSleep); XCTAssertNil(h.peakRecovery); XCTAssertNil(h.maxStrain)
        XCTAssertNil(h.sleepStreak); XCTAssertNil(h.lowestHRV)
        XCTAssertEqual(h.eligibleDays, 0)
        XCTAssertFalse(h.isPartialHistory)
    }

    func testPartialHistoryAndRangeUpdates() {
        let r = days(from: "2026-10-20", Array(repeating: 50, count: 10))
        let one = DataHighlights.compute(HighlightInputs(recovery: r), source: .noop, range: .month3, today: "2026-11-01")
        XCTAssertTrue(one.isPartialHistory)
        let all = DataHighlights.compute(HighlightInputs(recovery: r), source: .noop, range: .allTime, today: "2026-11-01")
        XCTAssertEqual(all.startDay, "2026-10-20")
        XCTAssertFalse(all.isPartialHistory)
    }

    func testSourceThresholdsAreLabelledSeparately() {
        let w = HighlightThresholds.for(.whoop), n = HighlightThresholds.for(.noop)
        XCTAssertTrue(w.recoveryLabel.contains("WHOOP"))
        XCTAssertTrue(n.recoveryLabel.contains("NOOP"))
        XCTAssertNotEqual(w.recoveryLabel, n.recoveryLabel)
    }

    func testRescoredValuesChangeRecords() {
        var s = days(from: "2026-10-01", [10, 11, 12])
        let before = DataHighlights.compute(HighlightInputs(strain: s), source: .noop, range: .allTime, today: "2026-10-10")
        s[2].value = 8
        let after = DataHighlights.compute(HighlightInputs(strain: s), source: .noop, range: .allTime, today: "2026-10-10")
        XCTAssertEqual(before.maxStrain?.value, 12)
        XCTAssertEqual(after.maxStrain?.value, 11)
        XCTAssertEqual(after.strainStreak?.days, 2)
    }
}
