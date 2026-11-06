import XCTest
@testable import StrandAnalytics

final class DayCoverageTests: XCTestCase {
    let day0 = 1_793_592_000   // an arbitrary midnight-aligned start; values below are offsets

    func testTodayComparesWithElapsedTimeNotTwentyHours() {
        // 08:10 now, recorded 00:00–07:42 continuously, synced through 08:05 (normal lag).
        let c = DayCoverage.compute(dayStart: day0, dayEnd: day0 + 86_400, now: day0 + 8 * 3600 + 600,
                                    intervals: [(day0, day0 + 7 * 3600 + 42 * 60)], syncedThrough: day0 + 8 * 3600 + 300)
        XCTAssertTrue(c.isToday)
        XCTAssertEqual(c.recordedSeconds, 7 * 3600 + 42 * 60)
        XCTAssertEqual(c.caption(), "7 h 42 min recorded so far.")
        XCTAssertEqual(c.gaps.count, 1)                        // 07:42 → 08:05 is in synced data: a real gap
        XCTAssertEqual(c.awaitingSyncSeconds, 300)              // 08:05 → 08:10 awaits the next sync
        XCTAssertFalse(c.warrantsWarning)
    }

    func testFutureTimeIsNeverMissing() {
        let c = DayCoverage.compute(dayStart: day0, dayEnd: day0 + 86_400, now: day0 - 60, intervals: [], syncedThrough: nil)
        XCTAssertTrue(c.isFuture)
        XCTAssertEqual(c.elapsedSeconds, 0)
        XCTAssertFalse(c.warrantsWarning)
        XCTAssertEqual(c.caption(), "This day hasn't started yet.")
    }

    func testJustAfterMidnight() {
        let c = DayCoverage.compute(dayStart: day0, dayEnd: day0 + 86_400, now: day0 + 120, intervals: [], syncedThrough: day0 - 300)
        XCTAssertEqual(c.elapsedSeconds, 120)
        XCTAssertEqual(c.awaitingSyncSeconds, 120)
        XCTAssertFalse(c.warrantsWarning)
    }

    func testPastDayUsesRealDSTLength() {
        let len = 25 * 3600   // fall-back day
        let c = DayCoverage.compute(dayStart: day0, dayEnd: day0 + len, now: day0 + 3 * 86_400,
                                    intervals: [(day0, day0 + len)], syncedThrough: day0 + 2 * 86_400)
        XCTAssertEqual(c.caption(), "25 h recorded of 25 h.")
        XCTAssertTrue(c.gaps.isEmpty)
        let spring = DayCoverage.compute(dayStart: day0, dayEnd: day0 + 23 * 3600, now: day0 + 3 * 86_400,
                                         intervals: [(day0 - 3600, day0 + 30 * 3600)], syncedThrough: nil)
        XCTAssertEqual(spring.recordedSeconds, 23 * 3600)        // clipped to the day
    }

    func testInternalGapsAreUnionedAndWarnOnlyWhenMeaningful() {
        let ivs = [(day0, day0 + 3600), (day0 + 1800, day0 + 7200),          // overlapping: unioned
                   (day0 + 10 * 3600, day0 + 24 * 3600)]
        let c = DayCoverage.compute(dayStart: day0, dayEnd: day0 + 86_400, now: day0 + 2 * 86_400, intervals: ivs, syncedThrough: day0 + 86_400)
        XCTAssertEqual(c.recordedSeconds, 2 * 3600 + 14 * 3600)
        XCTAssertEqual(c.gaps, [DayCoverage.Gap(start: day0 + 7200, end: day0 + 36_000)])
        XCTAssertTrue(c.warrantsWarning)
        XCTAssertFalse(c.details(clock: { _ in "x" }).joined().lowercased().contains("off"))   // never claims the strap was off
        let small = DayCoverage.compute(dayStart: day0, dayEnd: day0 + 86_400, now: day0 + 2 * 86_400,
                                        intervals: [(day0, day0 + 40_000), (day0 + 41_000, day0 + 86_400)], syncedThrough: day0 + 86_400)
        XCTAssertEqual(small.gaps.count, 1)
        XCTAssertFalse(small.warrantsWarning)
    }

    func testSyncLagWarnsOnlyWhenLong() {
        let lagged = DayCoverage.compute(dayStart: day0, dayEnd: day0 + 86_400, now: day0 + 12 * 3600,
                                         intervals: [(day0, day0 + 9 * 3600)], syncedThrough: day0 + 9 * 3600)
        XCTAssertEqual(lagged.awaitingSyncSeconds, 3 * 3600)
        XCTAssertTrue(lagged.warrantsWarning)
        XCTAssertTrue(lagged.details(clock: { _ in "09:00" }).contains("Data through 09:00."))
    }

    func testNoDataAndImportedSummaries() {
        let none = DayCoverage.compute(dayStart: day0, dayEnd: day0 + 86_400, now: day0 + 2 * 86_400, intervals: [], syncedThrough: nil)
        XCTAssertEqual(none.caption(), "No heart rate recorded for this day.")
        let imp = DayCoverage.compute(dayStart: day0, dayEnd: day0 + 86_400, now: day0 + 2 * 86_400, intervals: [], syncedThrough: nil,
                                      hasImportedSummary: true)
        XCTAssertTrue(imp.importedSummaryOnly)
        XCTAssertFalse(imp.warrantsWarning)
    }
}
